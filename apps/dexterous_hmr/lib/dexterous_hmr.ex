defmodule DexterousHMR do
  @moduledoc """
  Dev-only hot module replacement for Dexterous (paper Section 5.2.2,
  Algorithms 8–10, BEAM-flavored).

  ## Why BEAM collapses most of the paper's graph machinery

  The paper's Algorithm 8 propagates *accepted*/*declined* through the import
  graph because JS imports are bindings held by the importer. On the BEAM a
  remote call resolves the module atom at call time, so a replaced module is
  picked up by its callers on the next call — no cascade replacement needed.
  The compile-time dependency closure (structs, macros, behaviours) is already
  recompiled by Mix. So "change detection" reduces to comparing the md5 of
  loaded modules before and after a recompile; the graph work is the
  compiler's. Algorithm 9's stale-entry detection reduces to "an entry whose
  component module changed", and Algorithm 10's transactional reload becomes
  retire + respawn per stale entry, with the code server's two-version scheme
  providing backup (old code stays loadable) and rollback (load the old
  binary back).

  ## Known limitations

  * Externals (see `:externals`): their new code is *already loaded* by the
    compile step (module code is VM-global), so "not loading" them is
    impossible. The `:continue` mode simply leaves their entries alone — a
    hot module that calls a skipped external's *new* API may crash at runtime
    until a full restart.
  * Dev-only: `trigger_compile/1` refuses to work outside `:dev` unless a
    `:compile_fun` override is configured (the tests use this).
  * Protocol consolidation is not handled (dev does not consolidate).
  * No cross-node code distribution.

  ## Configuration

  Application env (`config :dexterous_hmr, :config, [...]`) provides global
  defaults; every option can be overridden per call/registration:

    * `:watch_dirs` — source directories tracked by change detection; only
      modules whose `:source` path falls under one are diffed (deps are
      naturally excluded).
    * `:rollback` — `:all` (default: any failure restores every changed
      module and rebuilds every stale entry) or `:per_module` (only the
      modules whose entries failed are restored).
    * `:settle_timeout` — ms to wait for the reload cascade to converge
      before rolling back (default 5000).
    * `:externals` — modules that cannot be hot-replaced. With
      `:externals_mode` `:continue` (default) they are skipped with a log and
      the `:on_external` callback; with `:reject_batch` their appearance
      aborts the whole batch.
    * `:protected` — extra modules hard-refused (on top of the default
      `Dexterous.*`, `DexterousLoader.*` and dexterous_hmr modules); see
      `:allow_reload` to explicitly opt out of protection.
    * `:allow_reload` — modules exempt from the protected set.
    * `:compile_fun` — overrides the recompile step (tests stub this).
    * `:on_external` / `:on_protected` — host callbacks `(module -> any)`
      fired when a module is refused; default logs.
  """

  use GenServer

  require Logger

  alias Dexterous.{Fiber, Store}
  alias DexterousLoader.Entry

  @framework_names ~w(Dexterous DexterousLoader DexterousHMR)
  @framework_prefixes ["Dexterous.", "DexterousLoader.", "DexterousHMR."]

  @default_config [
    watch_dirs: [],
    rollback: :all,
    settle_timeout: 5_000,
    externals: [],
    externals_mode: :continue,
    protected: [],
    allow_reload: [],
    compile_fun: nil,
    on_external: nil,
    on_protected: nil
  ]

  defmodule State do
    @moduledoc false
    defstruct loaders: %{}, running: false, pending: false, waiter: nil, cycle: nil,
              purge_queue: MapSet.new(), opts: []
  end

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register a loader (with per-loader option overrides) for trigger cycles."
  def register(loader, opts \\ []) do
    GenServer.call(loop_name(), {:register, loader, opts})
  end

  def unregister(loader) do
    GenServer.call(loop_name(), {:unregister, loader})
  end

  @doc "Registered loaders: `%{loader => opts}`."
  def registered do
    GenServer.call(loop_name(), :registered)
  end

  @doc "Introspection: `%{running:, pending:, loaders:, purge_queue:}`."
  def status do
    GenServer.call(loop_name(), :status)
  end

  @doc """
  Run one full HMR cycle: drain the pending purge queue, back up the watched
  modules' object code, recompile, diff, and transactionally replace the
  stale entries of every registered loader.

  Single-flight: while a cycle runs, further calls are coalesced and answered
  `{:ok, :queued}`; a queued cycle reruns when the current one finishes. The
  first (uncoalesced) caller receives the cycle's report.
  """
  def trigger_compile(opts \\ []) do
    GenServer.call(loop_name(), {:trigger_compile, opts}, :infinity)
  end

  @doc "IEx convenience: `recompile()` == `trigger_compile()`."
  def recompile(opts \\ []) do
    trigger_compile(opts)
  end

  ## ------------------------------------------------------------------
  ## Pure change detection (paper Phase 1+2, degenerate)
  ## ------------------------------------------------------------------

  @doc """
  Snapshot the watched local modules: `%{module => %{md5: binary}}`. A module
  is watched when the `:source` path recorded in its compile chunk falls under
  one of `watch_dirs`.
  """
  def snapshot(watch_dirs) do
    :code.all_loaded()
    |> Enum.filter(fn {mod, _} -> watched?(mod, watch_dirs) end)
    |> Map.new(fn {mod, _} -> {mod, %{md5: module_md5(mod)}} end)
  end

  @doc """
  The changed module set between two snapshots: modules present in only one,
  or whose md5 differs.
  """
  def diff(before, after_) do
    (Map.keys(before) ++ Map.keys(after_))
    |> Enum.uniq()
    |> Enum.filter(fn mod ->
      case {Map.get(before, mod), Map.get(after_, mod)} do
        {nil, _} -> true
        {_, nil} -> true
        {b, a} -> b.md5 != a.md5
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Live entry fibers whose component module is in `changed`:
  `[{fiber_id, pid, attrs}]` (paper Algorithm 9, degenerate: an entry's
  "dependency tree" is its own component module, since runtime dependencies
  are not bound on the BEAM).
  """
  def stale_entries(scope, changed) do
    scope
    |> Store.all_fibers()
    |> Enum.flat_map(fn {fid, attrs} ->
      case Map.get(attrs, :entry) do
        %Entry{component: component} when is_atom(component) ->
          if MapSet.member?(changed, component), do: [{fid, attrs.pid, attrs}], else: []

        _ ->
          []
      end
    end)
  end

  @doc """
  Drop stale entries that live under another stale entry: reloading the
  ancestor rebuilds the whole subtree from its entry records (with the new
  code already current), so reloading the descendants individually would
  double-rebuild — and could orphan a freshly spawned fiber under a retiring
  parent.
  """
  def topmost(scope, stale) do
    stale_fids = MapSet.new(stale, fn {fid, _pid, _attrs} -> fid end)

    Enum.filter(stale, fn {_fid, _pid, attrs} ->
      not stale_ancestor?(scope, attrs, stale_fids)
    end)
  end

  @doc """
  Split the changed set into accepted modules and refused ones. Refused are
  externals (skipped or batch-rejected per `:externals_mode`) and protected
  framework modules. Returns `{:ok, accepted, %{externals:, protected:}}` or
  `{:error, :externals_changed, externals}`.
  """
  def classify(changed, opts \\ []) do
    config = config(opts)
    externals = MapSet.new(Keyword.get(config, :externals))
    protected = protected_set(config)

    {accepted, ex_hits, pr_hits} =
      Enum.reduce(changed, {MapSet.new(), [], []}, fn mod, {acc, ex, pr} ->
        cond do
          MapSet.member?(externals, mod) -> {acc, [mod | ex], pr}
          MapSet.member?(protected, mod) -> {acc, ex, [mod | pr]}
          true -> {MapSet.put(acc, mod), ex, pr}
        end
      end)

    if ex_hits != [] and Keyword.get(config, :externals_mode) == :reject_batch do
      {:error, :externals_changed, Enum.reverse(ex_hits)}
    else
      {:ok, accepted, %{externals: Enum.reverse(ex_hits), protected: Enum.reverse(pr_hits)}}
    end
  end

  ## ------------------------------------------------------------------
  ## Transactional replace (paper Algorithm 10)
  ## ------------------------------------------------------------------

  @doc """
  Transactionally replace the entries whose component modules are in
  `changed` (one loader's view; the trigger cycle applies the same path to
  all registered loaders as a single transaction).

  `backup` maps each changed module to its pre-compile object code:
  `%{mod => %{binary: binary, file: file}}`. It must be taken *before* the
  compile step — rollback restores exactly those binaries.

  On success: every stale entry (topmost only) is retired and respawned, the
  reload cascade is awaited (`:settle_timeout`), and the old code is soft
  purged. Returns `{:ok, report}` with `%{changed:, accepted:, refused:,
  reloaded: [entry ids], purge_pending: [modules]}`.

  On failure (reload error, settle timeout, or a reloaded fiber ended
  `:failed`): restores the backup binaries (or removes modules that did not
  exist before), rebuilds the stale entries on the restored code, purges the
  new code, and returns `{:error, {failure, info}}`. Rollback granularity
  follows `:rollback` (`:all` default, `:per_module` when the failure is
  attributable).
  """
  def apply(loader, changed, backup \\ %{}, opts \\ []) when is_map(backup) do
    swap_all(%{loader => []}, changed, backup, opts)
  end

  @doc false
  # The global transaction over every registered loader: one changed set,
  # one backup, all scopes.
  def swap_all(loaders, changed, backup, opts) do
    config = config(opts)

    case classify(changed, config) do
      {:error, :externals_changed, exts} ->
        {:error, {:externals_changed, exts}}

      {:ok, accepted, refused} ->
        do_swap(loaders, changed, accepted, refused, backup, config)
    end
  end

  # The transaction proper: reload the stale entries, wait for the cascade to
  # converge, and either report success or roll back (Algorithm 10).
  defp do_swap(loaders, changed, accepted, refused, backup, config) do
    notify_refused(refused, config)

    if MapSet.size(accepted) == 0 do
      {:ok, noop_report(changed, refused)}
    else
      scopes = loader_scopes(loaders)
      {per_loader_top, _flat_ids} = stale_by_loader(loaders, accepted)

      ctx = %{
        all_ids: entry_ids(per_loader_top),
        scopes: scopes,
        failed_before: failed_fiber_ids(scopes),
        changed: changed,
        refused: refused
      }

      case reload_all(loaders, per_loader_top) do
        {:error, reason} ->
          rollback(loaders, per_loader_top, accepted, backup, config, {:reload_failed, reason})

        :ok ->
          await_convergence(ctx, loaders, per_loader_top, accepted, backup, config)
      end
    end
  end

  # The convergence barrier: a settle timeout or a reloaded fiber ending
  # :failed rolls the batch back; otherwise report success.
  defp await_convergence(ctx, loaders, per_loader_top, accepted, backup, config) do
    case wait_settled(ctx.scopes, Keyword.get(config, :settle_timeout)) do
      :ok ->
        failed = failed_fiber_ids(ctx.scopes) -- ctx.failed_before

        if failed != [] do
          rollback(loaders, per_loader_top, accepted, backup, config, {:fiber_failed, failed})
        else
          {:ok, ok_report(ctx.changed, accepted, ctx.refused, ctx.all_ids)}
        end

      {:error, reason} ->
        rollback(loaders, per_loader_top, accepted, backup, config, {:settle_timeout, reason})
    end
  end

  defp entry_ids(per_loader_top) do
    per_loader_top
    |> Map.values()
    |> Enum.flat_map(fn pairs -> Enum.map(pairs, &elem(&1, 0)) end)
  end

  defp noop_report(changed, refused) do
    %{
      changed: MapSet.to_list(changed),
      accepted: [],
      refused: refused,
      reloaded: [],
      purge_pending: []
    }
  end

  defp ok_report(changed, accepted, refused, all_ids) do
    %{
      changed: MapSet.to_list(changed),
      accepted: MapSet.to_list(accepted),
      refused: refused,
      reloaded: all_ids,
      purge_pending: purge(accepted)
    }
  end

  ## ------------------------------------------------------------------
  ## The HMR loop (single GenServer, single-flight, coalescing)
  ## ------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, %State{opts: opts}}
  end

  @impl true
  def handle_call({:register, loader, lopts}, _from, state) do
    {:reply, :ok, %{state | loaders: Map.put(state.loaders, loader, lopts)}}
  end

  def handle_call({:unregister, loader}, _from, state) do
    {:reply, :ok, %{state | loaders: Map.delete(state.loaders, loader)}}
  end

  def handle_call(:registered, _from, state) do
    {:reply, state.loaders, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: state.running,
       pending: state.pending,
       loaders: Map.keys(state.loaders),
       purge_queue: MapSet.to_list(state.purge_queue)
     }, state}
  end

  def handle_call({:trigger_compile, opts}, from, state) do
    if state.running do
      # Coalesce: record the event; a rerun happens when the cycle ends.
      GenServer.reply(from, {:ok, :queued})
      {:noreply, %{state | pending: true}}
    else
      me = self()

      {pid, _mon} =
        spawn_monitor(fn ->
          {result, delta} = run_cycle(%{state | opts: opts})
          send(me, {:hmr_cycle_done, self(), result, delta})
        end)

      {:noreply, %{state | running: true, waiter: from, cycle: pid}}
    end
  end

  @impl true
  def handle_info({:hmr_cycle_done, _pid, result, delta}, state) do
    queue = state.purge_queue
    queue = MapSet.difference(queue, MapSet.new(delta.removed))
    queue = MapSet.union(queue, MapSet.new(delta.added))
    state = %{state | purge_queue: queue}

    state =
      if state.waiter do
        GenServer.reply(state.waiter, result)
        %{state | waiter: nil}
      else
        state
      end

    if state.pending do
      # A trigger arrived mid-cycle: rerun with the fresh snapshot.
      me = self()

      {pid, _mon} =
        spawn_monitor(fn ->
          {result, delta} = run_cycle(state)
          send(me, {:hmr_cycle_done, self(), result, delta})
        end)

      {:noreply, %{state | pending: false, cycle: pid}}
    else
      {:noreply, %{state | running: false, cycle: nil}}
    end
  end

  def handle_info({:DOWN, _mon, :process, pid, _reason}, state) do
    # The cycle process died without reporting (run_cycle catches, so this
    # should not happen); fail the waiter rather than hang it.
    if state.cycle == pid do
      if state.waiter, do: GenServer.reply(state.waiter, {:error, :cycle_crashed})
      {:noreply, %{state | running: false, pending: false, waiter: nil, cycle: nil}}
    else
      {:noreply, state}
    end
  end

  ## ------------------------------------------------------------------
  ## Cycle internals
  ## ------------------------------------------------------------------

  # Runs in the spawned cycle process; never raises. Returns
  # `{result, %{added: [modules], removed: [modules]}}` so the loop can keep
  # its purge queue in sync.
  defp run_cycle(state) do
      do_cycle(state)
    catch
      kind, reason -> {{:error, {:cycle_exception, kind, reason}}, %{added: [], removed: []}}
  end

  defp do_cycle(state) do
    config = config(state.opts)

    case env_guard(config) do
      {:error, reason} ->
        {{:error, reason}, %{added: [], removed: []}}

      :ok ->
        {drained, _remaining} = drain_purge_queue(state.purge_queue)
        backup = take_backup(Keyword.get(config, :watch_dirs))
        before = snapshot(Keyword.get(config, :watch_dirs))

        case compile(config) do
          {:error, reason} ->
            {{:error, reason}, %{added: [], removed: []}}

          :ok ->
            after_ = snapshot(Keyword.get(config, :watch_dirs))
            changed = diff(before, after_)
            result = swap_all(state.loaders, changed, backup, config)
            {result, %{added: purge_pending_of(result), removed: drained}}
        end
    end
  end

  defp env_guard(config) do
    case Keyword.get(config, :compile_fun) do
      fun when is_function(fun, 0) ->
        :ok

      _ ->
        # Mix is a build-time tool, not a runtime dependency: probe it
        # dynamically (see compile/1) so dialyzer — which analyzes against
        # the app's runtime code paths — does not flag the call.
        if Code.ensure_loaded?(Mix) and Kernel.apply(Mix, :env, []) == :dev do
          :ok
        else
          {:error, :not_dev}
        end
    end
  end

  defp compile(config) do
    case Keyword.get(config, :compile_fun) do
      fun when is_function(fun, 0) ->
        fun.()
        :ok

      _ ->
        # Mix ships with the toolchain, not with the app: dispatch
        # dynamically and fail cleanly when it is genuinely absent (e.g. in
        # a release), instead of crashing on an undefined function.
        if Code.ensure_loaded?(Mix) and Code.ensure_loaded?(Mix.Task) do
          Kernel.apply(Mix.Task, :reenable, ["compile.elixir"])
          Kernel.apply(Mix.Task, :reenable, ["compile"])
          Kernel.apply(Mix.Task, :run, ["compile"])
          :ok
        else
          {:error, :mix_not_available}
        end
    end
  end

  # Pre-compile object code of every watched module; rollback restores these
  # exact binaries.
  defp take_backup(watch_dirs) do
    :code.all_loaded()
    |> Enum.filter(fn {mod, _} -> watched?(mod, watch_dirs) end)
    |> Map.new(fn {mod, _} ->
      case :code.get_object_code(mod) do
        {^mod, binary, file} -> {mod, %{binary: binary, file: file}}
        :error -> {mod, %{binary: nil, file: nil}}
      end
    end)
  end

  # Retry modules whose old code could not be purged (still executing). The
  # queue is drained at the start of the next cycle, before any third version
  # can be loaded (never accumulate to a third generation). Returns
  # `{purged, still_pending}`.
  defp drain_purge_queue(queue) do
    Enum.split_with(queue, fn mod ->
      case :code.soft_purge(mod) do
        true ->
          true

        false ->
          Logger.warning("dexterous_hmr: old code of #{inspect(mod)} still in use; will retry")
          false
      end
    end)
  end

  defp purge_pending_of(result) do
    case result do
      {:ok, report} -> Map.get(report, :purge_pending, [])
      {:error, {_failure, info}} -> Map.get(info, :purge_pending, [])
      # _ -> []
    end
  end

  ## ------------------------------------------------------------------
  ## Stale-entry computation per loader
  ## ------------------------------------------------------------------

  defp loader_scopes(loaders) do
    Enum.map(loaders, fn {loader, _lopts} -> DexterousLoader.scope(loader) end)
  end

  # Group the stale entries per loader scope, keeping only topmost stale
  # entries (descendants are rebuilt by their reloaded ancestor). Returns
  # `{%{loader => [{entry_id, component}]}, flat_id_list}`.
  defp stale_by_loader(loaders, accepted) do
    {per_loader, flat} =
      Enum.reduce(loaders, {%{}, []}, fn {loader, _lopts}, {acc, flat} ->
        scope = DexterousLoader.scope(loader)
        top = topmost(scope, stale_entries(scope, accepted))

        pairs =
          Enum.map(top, fn {_fid, _pid, attrs} ->
            {Map.fetch!(attrs, :entry_id), Map.fetch!(attrs, :entry).component}
          end)

        {Map.put(acc, loader, pairs), flat ++ Enum.map(pairs, &elem(&1, 0))}
      end)

    {per_loader, flat}
  end

  defp reload_all(loaders, per_loader_top) do
    Enum.reduce_while(loaders, :ok, fn {loader, _lopts}, :ok ->
      ids = Enum.map(Map.get(per_loader_top, loader, []), &elem(&1, 0))

      case reload_ids(loader, ids) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reload_ids(_loader, []), do: :ok

  defp reload_ids(loader, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case DexterousLoader.reload_entry(loader, id) do
        :ok ->
          {:cont, :ok}

        # The fiber vanished between detection and reload: it was already
        # replaced by a reloaded ancestor — nothing to do.
        {:error, :not_found} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  ## ------------------------------------------------------------------
  ## Convergence barrier and failure detection
  ## ------------------------------------------------------------------

  defp wait_settled(scopes, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_poll(scopes, deadline)
  end

  defp wait_poll(scopes, deadline) do
    case unsettled(scopes) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          wait_poll(scopes, deadline)
        end
    end
  end

  # A fiber is unsettled while it is transitioning (loading/unloading) or
  # running an update — the cascade has not converged. :failed counts as
  # settled for the barrier; failures are detected separately.
  defp unsettled(scopes) do
    Enum.flat_map(scopes, fn scope ->
      scope
      |> Store.all_fibers()
      |> Enum.flat_map(fn {fid, attrs} ->
        try do
          case Fiber.status(attrs.pid) do
            %{state: state, updating: updating}
            when state in [:loading, :unloading] or updating ->
              [fid]

            _ ->
              []
          end
        catch
          # A dead pid mid-retirement: it is going away, not blocking us.
          :exit, _ -> []
        end
      end)
    end)
  end

  defp failed_fiber_ids(scopes) do
    Enum.flat_map(scopes, fn scope ->
      scope
      |> Store.all_fibers()
      |> Enum.flat_map(fn {fid, attrs} ->
        try do
          case Fiber.status(attrs.pid) do
            %{state: :failed} -> [fid]
            _ -> []
          end
        catch
          :exit, _ -> []
        end
      end)
    end)
  end

  ## ------------------------------------------------------------------
  ## Purge and rollback
  ## ------------------------------------------------------------------

  # Soft-purge the old version of each module; returns the modules still in
  # use (queued for the next cycle's drain).
  defp purge(modules) do
    Enum.filter(modules, fn mod ->
      :code.soft_purge(mod) != true
    end)
  end

  defp rollback(loaders, per_loader_top, accepted, backup, config, failure) do
    scopes = loader_scopes(loaders)

    targets =
      case Keyword.get(config, :rollback) do
        :per_module ->
          case attributable(failure, loaders) do
            :all -> accepted
            set -> set
          end

        _all ->
          accepted
      end

    # 1. Restore the old code: load the backed-up binary back (it becomes
    # current; the new version becomes old), or remove modules that did not
    # exist before the compile.
    Enum.each(targets, fn mod ->
      case Map.get(backup, mod) do
        %{binary: binary, file: file} when is_binary(binary) ->
          file = file || Atom.to_string(mod) <> ".beam"
          :code.load_binary(mod, String.to_charlist(file), binary)

        _no_old_version ->
          # The module did not exist before the compile: remove it entirely.
          # Order matters: purge any old version first (delete refuses while
          # old code exists), then delete the current one and purge it.
          :code.purge(mod)
          :code.delete(mod)
          :code.purge(mod)
      end
    end)

    # 2. Rebuild only the stale entries of the target modules, and converge.
    per_loader_targets =
      Map.new(per_loader_top, fn {loader, pairs} ->
        kept =
          for {id, component} <- pairs, MapSet.member?(targets, component) do
            {id, component}
          end

        {loader, kept}
      end)

    reload_all(loaders, per_loader_targets)
    wait_settled(scopes, Keyword.get(config, :settle_timeout))

    # 3. The new version is now old and nobody runs it: purge it.
    purge_pending = purge(targets)

    {:error, {failure, %{modules: MapSet.to_list(targets), purge_pending: purge_pending}}}
  end

  # For :per_module rollback, attribute the failure to modules: a fiber
  # failure points at the components of the failed fibers; an un-attributable
  # failure (timeout, reload error) falls back to :all.
  defp attributable({:fiber_failed, failed_fids}, loaders) do
    failed = MapSet.new(failed_fids)

    loaders
    |> loader_scopes()
    |> Enum.flat_map(&Store.all_fibers/1)
    |> Enum.flat_map(fn {fid, attrs} ->
      if MapSet.member?(failed, fid) do
        case Map.get(attrs, :entry) do
          %Entry{component: component} -> [component]
          _ -> []
        end
      else
        []
      end
    end)
    |> MapSet.new()
  end

  # An un-attributable failure (settle timeout, reload error) cannot be
  # pinned to specific modules under :per_module — fall back to :all.
  defp attributable(_failure, _loaders), do: :all

  ## ------------------------------------------------------------------
  ## Classification helpers
  ## ------------------------------------------------------------------

  defp notify_refused(%{externals: externals, protected: protected}, config) do
    Enum.each(externals, &notify_refused(:external, &1, config))
    Enum.each(protected, &notify_refused(:protected, &1, config))
  end

  defp notify_refused(kind, mod, config) do
    key = if kind == :external, do: :on_external, else: :on_protected

    case Keyword.get(config, key) do
      fun when is_function(fun, 1) ->
        fun.(mod)

      _ ->
        Logger.warning("dexterous_hmr: #{kind} module #{inspect(mod)} changed; not hot-replaced")
    end
  end

  defp protected_set(config) do
    framework =
      :code.all_loaded()
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.filter(&framework?/1)

    (framework ++ Keyword.get(config, :protected))
    |> Kernel.--(Keyword.get(config, :allow_reload))
    |> MapSet.new()
  end

  defp framework?(mod) when is_atom(mod) do
    name = Atom.to_string(mod)
    name = if String.starts_with?(name, "Elixir."), do: String.slice(name, 7..-1//1), else: name
    name in @framework_names or Enum.any?(@framework_prefixes, &String.starts_with?(name, &1))
  end

  defp framework?(_), do: false

  ## ------------------------------------------------------------------
  ## Config resolution (app env defaults, call-level overrides)
  ## ------------------------------------------------------------------

  def config(opts) do
    @default_config
    |> Keyword.merge(Application.get_env(:dexterous_hmr, :config, []))
    |> Keyword.merge(opts)
  end

  ## ------------------------------------------------------------------
  ## Snapshot helpers
  ## ------------------------------------------------------------------

  defp watched?(mod, watch_dirs) do
    # The Elixir compiler's internal :elixir_* modules carry the file being
    # compiled in their compile info and would pollute the diff.
    if String.starts_with?(Atom.to_string(mod), "elixir_") do
      false
    else
      case source_path(mod) do
        nil -> false
        path -> Enum.any?(watch_dirs, &path_under?(path, &1))
      end
    end
  end

  defp source_path(mod) do
    case Keyword.get(mod.module_info(:compile), :source) do
      nil -> nil
      path -> to_string(path)
    end
  end

  defp path_under?(path, dir) do
    p = String.replace(to_string(path), "\\", "/") |> String.downcase()
    d = String.replace(to_string(dir), "\\", "/") |> String.trim_trailing("/") |> String.downcase()
    String.starts_with?(p, d <> "/")
  end

  defp module_md5(mod) do
    mod.module_info(:md5)
  rescue
    _ -> nil
  end

  defp stale_ancestor?(scope, attrs, stale_fids) do
    case Map.get(attrs, :parent) do
      nil ->
        false

      parent ->
        if MapSet.member?(stale_fids, parent) do
          true
        else
          case Store.get_fiber(scope, parent) do
            {:ok, parent_attrs} -> stale_ancestor?(scope, parent_attrs, stale_fids)
            :error -> false
          end
        end
    end
  end

  defp loop_name, do: Process.whereis(__MODULE__) || __MODULE__
end
