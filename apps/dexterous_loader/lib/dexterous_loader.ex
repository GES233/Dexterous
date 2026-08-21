defmodule DexterousLoader do
  @moduledoc """
  The declarative component loader (paper Section 5.2).

  An orchestrator specifies the desired composition as a list of
  `DexterousLoader.Entry` records; the loader instantiates them as fibers and
  keeps them in step with the specification across `reconcile/2` calls.

  Reconciliation diffs by entry `id`:

    * a new id is instantiated;
    * a vanished id is retired;
    * an intercept-only change updates the fiber's metadata in place — it is
      consulted at read time, so no reload is needed (paper Section 5.2.1);
    * a config-only change is handed to the component's `update/3` when it
      exports one (paper Section 5.2.1); a config change aimed at a
      non-active fiber rebuilds it instead of dropping the change;
    * an isolate change reassigns the entry's realms in place (paper
      Algorithm 7, `DexterousLoader.Isolate`);
    * an id that vanished from one parent and appeared under another is a
      relocation: the fiber is moved (the `move/3` machinery) rather than
      deleted and recreated;
    * any other change rebuilds the entry (retired and re-instantiated) —
      rebuilding is sound: the departing fiber's contribution to the state is
      nothing (paper Corollary 62).

  The binding between an entry and its fiber runs in both directions: a
  component may revise its own record with `Dexterous.Context.write_back/2`
  (and disable itself with `disabled: true` + `Dexterous.Context.retire_self/1`);
  the loader adopts such revisions as the reconcile baseline.

  Nested composition goes through `DexterousLoader.Group`, an ordinary
  component whose config is a list of child entries; its config changes are
  applied as a keyed diff over child ids, so reconciliation recurses down
  the tree without rebuilding surviving subtrees. `DexterousLoader.Include`
  grafts a subtree from an external JSON configuration file;
  `write_entries/2` / `load_entries/1` persist and read back the
  authoritative record.

  `validate/1` statically checks a configuration's declarations (paper
  Section 6.5): dependency cycles and duplicate provisions of one key in one
  realm are reported (via `Logger`) at load and reconcile time.

  `move/3` relocates an entry to another group (or the root) while keeping
  its fiber — the equivalent of cordis's `EntryTree.update(id, opts, parent)`.
  Entry ids must be unique across the whole tree within a scope, since moves
  and child bookkeeping identify fibers by entry id.
  """

  use GenServer

  require Logger

  alias Dexterous.{Context, Fiber, Store}
  alias DexterousLoader.{Entry, Group, Isolate}

  defstruct ctx: nil, fibers: %{}

  ## API

  def start_link(%Context{} = ctx, [%Entry{} | _] = entries) do
    GenServer.start_link(__MODULE__, {ctx, entries})
  end

  @doc """
  Statically check a configuration's dependency declarations (paper
  Section 6.5): a dependency cycle is predictable from the declarations
  alone, so it is reported at load time instead of leaving the involved
  fibers permanently inactive. Also reported: two enabled entries declaring
  a provision of the same key in the same realm (the O-Insert single-source
  discipline — each key has one possible provider).

  Returns `:ok` or `{:error, issues}`, each issue being `{:cycle, path}` or
  `{:duplicate_provision, key, realm, ids}`. Only the static tree is
  checked: bindings installed from the root context and subtrees an
  `Include` loads at runtime are invisible to this check, as are cycles
  introduced by runtime realm reassignment.
  """
  def validate(entries) when is_list(entries) do
    declarations = entry_declarations(entries, %{})

    provided =
      for declaration <- declarations,
          not declaration.disabled,
          key <- Dexterous.Component.provide_of(declaration.component) do
        realm = Map.get(declaration.isolate, key, key)
        {realm, key, declaration.id}
      end

    duplicates =
      provided
      |> Enum.group_by(fn {realm, _key, _id} -> realm end, fn {_realm, key, id} -> {key, id} end)
      |> Enum.flat_map(fn
        {_realm, [_single]} -> []
        {realm, key_ids} -> [{:duplicate_provision, key_ids |> hd() |> elem(0), realm, Enum.map(key_ids, &elem(&1, 1))}]
      end)

    provider_by_realm = Map.new(provided, fn {realm, _key, id} -> {realm, id} end)

    edges =
      for declaration <- declarations,
          not declaration.disabled,
          key <- Dexterous.Component.inject_keys_of(declaration.component),
          realm = Map.get(declaration.isolate, key, key),
          %{^realm => provider_id} <- [provider_by_realm],
          provider_id != declaration.id,
          do: {declaration.id, provider_id}

    issues = duplicates ++ Enum.map(find_cycles(edges), &{:cycle, &1})
    if issues == [], do: :ok, else: {:error, issues}
  end

  # Every entry in the (possibly nested) tree with its full realm map.
  defp entry_declarations(entries, parent_isolate) do
    Enum.flat_map(entries, fn entry ->
      isolate = Isolate.isolate_map(entry, parent_isolate)

      own = %{
        id: entry.id,
        isolate: isolate,
        component: entry.component,
        disabled: entry.disabled
      }

      children = if group?(entry), do: entry_declarations(entry.config, isolate), else: []
      [own | children]
    end)
  end

  # Simple DFS cycle hunt over the id → provider-id edges; cycles are
  # reported as the id path, deduplicated up to rotation.
  defp find_cycles(edges) do
    adjacency = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))

    adjacency
    |> Map.keys()
    |> Enum.flat_map(fn start -> walk_cycles(start, adjacency, [start], MapSet.new([start])) end)
    |> Enum.uniq_by(fn path -> Enum.sort(path) end)
  end

  defp walk_cycles(node, adjacency, path, seen) do
    Enum.flat_map(Map.get(adjacency, node, []), fn next ->
      cond do
        next in path ->
          # Closed a loop: report the cycle from `next` back to `next`.
          [path |> Enum.reverse() |> Enum.drop_while(&(&1 != next))]

        MapSet.member?(seen, next) ->
          []

        true ->
          walk_cycles(next, adjacency, [next | path], MapSet.put(seen, next))
      end
    end)
  end

  # Report declaration issues at load/reconcile time; the composition still
  # loads (a cycle's fibers stay inactive, as the calculus prescribes).
  defp report_issues(entries) do
    case validate(entries) do
      :ok ->
        :ok

      {:error, issues} ->
        for issue <- issues do
          Logger.warning("dexterous_loader: " <> format_issue(issue))
        end

        :ok
    end
  end

  defp format_issue({:cycle, path}) do
    chain = Enum.map_join(path ++ [hd(path)], " -> ", &inspect/1)

    "dependency cycle among entries #{chain}: the involved fibers will stay " <>
      "permanently inactive (paper Section 6.5)"
  end

  defp format_issue({:duplicate_provision, key, realm, ids}) do
    "entries #{Enum.map_join(ids, ", ", &inspect/1)} all declare a provision of " <>
      "#{inspect(key)} in realm #{inspect(realm)}: each key has one possible provider " <>
      "(paper O-Insert)"
  end

  @doc "Bring the running composition in step with `entries`."
  def reconcile(loader, entries) do
    GenServer.call(loader, {:reconcile, entries})
  end

  @doc """
  Move an entry to another parent — `:root` or `{:group, group_id}` —
  while preserving its fiber.

  The fiber keeps its identity: its parent attribute is re-pointed and its
  realm map is recomputed against the new parent (a realm reassignment per
  paper Algorithm 7 whenever the inherited realms differ, moving the
  bindings the entry owns). The loader's snapshot of the source and target
  groups is rewritten, so a later `reconcile/2` with the same logical tree
  is a no-op.

  Relocating an entry by editing the tree and reconciling is detected and
  routed through this same machinery; use this function for an explicit,
  programmatic move. Returns `:ok` or `{:error, reason}`.
  """
  def move(loader, id, target) do
    GenServer.call(loader, {:move, id, target})
  end

  @doc """
  Reload one entry's fiber in place: retire the live fiber and respawn it
  from the same entry record (the HMR primitive of paper Algorithm 10).

  The entry record — component module, config, annotations — is unchanged;
  only the component's code is expected to have been replaced (dev
  recompilation), so the fresh fiber runs the new module. Returns `:ok`, or
  `{:error, :not_found}` when no live fiber carries the entry id (disabled
  entries have none).

  A caller that enumerated stale entries from the live fibers may treat
  `:not_found` as benign: the fiber was already replaced by a reloaded
  ancestor, so its entry was rebuilt with the new code along the way.
  """
  def reload_entry(loader, id) do
    GenServer.call(loader, {:reload_entries, [id]})
  end

  @doc "Reload several entries in one call; stops at the first failure."
  def reload_entries(loader, ids) when is_list(ids) do
    GenServer.call(loader, {:reload_entries, ids})
  end

  @doc "The scope this loader's composition runs in."
  def scope(loader) do
    GenServer.call(loader, :scope)
  end

  @doc """
  Read a JSON configuration file into a list of entries (the persisted form
  of the authoritative record, paper Section 5.2.1). The file holds a JSON
  array of entry maps as produced by `DexterousLoader.Entry.to_map/1`.
  """
  def load_entries(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- decode_json(content) do
      {:ok, Enum.map(decoded, &Entry.from_map/1)}
    end
  end

  @doc """
  Persist a list of entries to a JSON configuration file, in the form
  `load_entries/1` reads back. See `DexterousLoader.Entry.to_map/1` for the
  restrictions on what entries can be persisted.
  """
  def write_entries(path, entries) when is_binary(path) and is_list(entries) do
    json = :json.encode(Enum.map(entries, &Entry.to_map/1))
    File.write(path, IO.iodata_to_binary(json))
  end

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    error -> {:error, {:invalid_json, error}}
  end

  @doc "The currently managed top-level fibers: `%{entry_id => %{entry:, pid:}}`."
  def fibers(loader) do
    GenServer.call(loader, :fibers)
  end

  @doc """
  Instantiate one enabled entry on `ctx`, applying its isolate/intercept
  annotations. Shared by the loader itself and by `DexterousLoader.Group`.
  """
  def spawn_entry(%Context{} = ctx, %Entry{} = entry) do
    child_ctx = apply_annotations(ctx, entry)

    {:ok, pid} =
      Context.use(child_ctx, entry.component, entry.config,
        attrs: %{entry_id: entry.id, entry: entry}
      )

    pid
  end

  @doc false
  # The per-field reconciliation dispatch for one surviving entry, shared by
  # the top-level loader and by Group's keyed child diff. Returns the entry's
  # (possibly new) fiber pid, or nil when the entry ends up disabled.
  #
  # Dispatch (paper Section 5.2.1): an intercept-only change updates the
  # fiber's metadata in place (it is consulted at read time, so no reload);
  # a config-only change goes to the component's update/3; an isolate change
  # reassigns realms (Algorithm 7), absorbing any config/intercept change
  # alongside; anything else rebuilds. A config change aimed at a non-active
  # fiber rebuilds instead: a reconfigure cast would be silently dropped and
  # the snapshot would drift from the running fiber (paper Section 4.3.4:
  # recovery from failure is orchestrator-driven, and the loader is the
  # orchestrator). Realm and intercept patches are meaningful in any state.
  def reconcile_child(%Context{} = ctx, %Entry{} = old, %Entry{} = new, pid) do
    cond do
      new.disabled ->
        Fiber.retire(pid)
        nil

      old == new ->
        pid

      true ->
        apply_change(ctx, old, new, pid)
    end
  end

  defp apply_change(%Context{} = ctx, %Entry{} = old, %Entry{} = new, pid) do
    same_core? = old.component == new.component and old.disabled == new.disabled
    config_same? = old.config == new.config

    cond do
      not same_core? ->
        rebuild(ctx, pid, new)

      not config_same? and not active?(pid) ->
        rebuild(ctx, pid, new)

      true ->
        apply_cooperative_change(ctx, old, new, pid)
    end
  end

  # The fiber is active and its identity, component and disabled flag are
  # unchanged: realm, config and interception changes can all be absorbed
  # without a rebuild.
  defp apply_cooperative_change(%Context{} = ctx, %Entry{} = old, %Entry{} = new, pid) do
    isolate_same? = old.isolate == new.isolate
    intercept_same? = old.intercept == new.intercept
    config_same? = old.config == new.config

    cond do
      not isolate_same? ->
        # Paper Algorithm 7: reassign the entry's realms in place; config and
        # intercept changes ride along (absorbed by the forced reload / the
        # metadata replacement).
        opts =
          if intercept_same?,
            do: [],
            else: [intercept: merged_intercept(ctx, new)]

        Isolate.patch(ctx, pid, new, opts)
        pid

      not config_same? and updatable?(new.component) ->
        # Paper Section 5.2.1: a config change is handed to the component,
        # which decides how to apply the new payload.
        unless intercept_same?, do: Fiber.patch_intercept(pid, merged_intercept(ctx, new))
        Fiber.reconfigure(pid, new.config)
        put_entry_record(ctx.scope, pid, new)
        pid

      not config_same? ->
        rebuild(ctx, pid, new)

      not intercept_same? ->
        # Interception metadata is consulted at read time: update in place.
        Fiber.patch_intercept(pid, merged_intercept(ctx, new))
        put_entry_record(ctx.scope, pid, new)
        pid

      true ->
        pid
    end
  end

  ## GenServer callbacks

  @impl true
  def init({ctx, entries}) do
    report_issues(entries)
    {:ok, %__MODULE__{ctx: ctx, fibers: instantiate_all(ctx, entries)}}
  end

  @impl true
  def handle_call({:reconcile, entries}, _from, state) do
    report_issues(entries)
    # Adopt any write-backs (paper Section 5.2.1: a component may revise its
    # own entry between reconciles) as the baseline the spec diffs against.
    state = sync_records(state)

    # An id that vanished from one parent and appeared under another is a
    # relocation: move the fiber (as `move/3` does) rather than letting the
    # diff delete and recreate it.
    state = apply_detected_moves(state, entries)

    new_by_id = Map.new(entries, &{&1.id, &1})

    # Retire entries that vanished.
    for {id, %{pid: pid}} <- state.fibers, not Map.has_key?(new_by_id, id) do
      Dexterous.Fiber.retire(pid)
    end

    fibers =
      Map.new(new_by_id, fn {id, entry} ->
        case Map.get(state.fibers, id) do
          %{entry: old, pid: pid} when old == entry and not entry.disabled ->
            {id, %{entry: entry, pid: pid}}

          %{entry: old, pid: pid} ->
            case reconcile_child(state.ctx, old, entry, pid) do
              nil -> {id, nil}
              pid -> {id, %{entry: entry, pid: pid}}
            end

          nil ->
            {id, spawn(state.ctx, entry)}
        end
      end)

    fibers = Map.reject(fibers, fn {_id, fiber} -> is_nil(fiber) end)
    {:reply, :ok, %{state | fibers: fibers}}
  end

  def handle_call({:move, id, target}, _from, state) do
    entries = top_entries(state)

    with {:ok, entry, source} <- locate(state, id),
         :ok <- validate_target(entries, id, source, target),
         :ok <- await_settled(state, source, target, 500) do
      {:reply, :ok, do_move(state, entry, source, target)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reload_entries, ids}, _from, state) do
    {result, state} =
      Enum.reduce_while(ids, {:ok, state}, fn id, {:ok, state} ->
        case reload_one(state, id) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason} -> {:halt, {{:error, reason}, state}}
        end
      end)

    {:reply, result, state}
  end

  def handle_call(:fibers, _from, state) do
    {:reply, state.fibers, state}
  end

  def handle_call(:scope, _from, state) do
    {:reply, state.ctx.scope, state}
  end

  ## Internal: reloads

  # One entry's in-place reload (paper Algorithm 10): retire the live fiber
  # and respawn it from its own entry record. Top-level entries re-register
  # their new pid in the loader snapshot, so a later reconcile never holds a
  # dead pid; nested entries need no loader bookkeeping — the parent group's
  # next keyed diff adopts the fresh fiber by entry id.
  defp reload_one(state, id) do
    scope = state.ctx.scope

    case find_fiber(scope, id) do
      nil ->
        {:error, :not_found}

      {_fiber_id, pid, attrs} ->
        case parent_ctx_for(state, attrs) do
          {:error, :parent_gone} ->
            # The parent fiber is gone (retired or reloaded first). Respawning
            # under the loader's root context would silently change the entry's
            # inherited realms — refuse instead: the caller decides whether
            # that is an expected cascade (an ancestor reload) or a real
            # failure.
            {:error, :parent_gone}

          {:ok, parent_ctx} ->
            Fiber.retire(pid)
            new_pid = spawn_entry(parent_ctx, attrs.entry)

            state =
              if Map.has_key?(state.fibers, id) do
                %{state | fibers: Map.put(state.fibers, id, %{entry: attrs.entry, pid: new_pid})}
              else
                state
              end

            {:ok, state}
        end
    end
  end

  # Rebuild the context the entry was spawned on from fiber attributes alone:
  # a top-level entry spawns on the loader's root context; a nested entry on
  # the context of its parent fiber — whose realm map and interception
  # metadata live in the parent's attributes, pure data, no group fiber
  # involvement needed.
  defp parent_ctx_for(state, %{parent: nil}), do: {:ok, state.ctx}

  defp parent_ctx_for(state, %{parent: parent_fid}) do
    scope = state.ctx.scope

    case Store.get_fiber(scope, parent_fid) do
      {:ok, parent_attrs} ->
        {:ok,
         %Context{
           fiber: parent_fid,
           scope: scope,
           isolate: Map.get(parent_attrs, :isolate, %{}),
           intercept: Map.get(parent_attrs, :intercept, %{})
         }}

      :error ->
        {:error, :parent_gone}
    end
  end

  ## Internal: moves

  # Relocations visible between the snapshot tree and the incoming spec: an
  # entry id whose immediate parent changed while its record stayed the
  # same. Each detected move goes through the same pipeline as `move/3`.
  # A relocation whose record also changed falls back to delete + recreate
  # in the standard diff (the move machinery patches realms from the new
  # record, so a config change riding along could be lost); so does a move
  # that does not validate (busy groups, an invalid target).
  defp apply_detected_moves(state, new_entries) do
    old_entries = top_entries(state)
    old_locations = locations(old_entries)
    new_locations = locations(new_entries)

    moves =
      for {id, new_location} <- new_locations,
          old_location = Map.get(old_locations, id),
          not is_nil(old_location),
          old_location != new_location,
          find_fiber(state.ctx.scope, id) != nil,
          {:ok, old_entry} <- [fetch_entry(old_entries, id)],
          {:ok, new_entry} <- [fetch_entry(new_entries, id)],
          old_entry == new_entry,
          do: {id, old_location, new_location}

    Enum.reduce(moves, state, fn {id, source, target}, state ->
      with {:ok, entry} <- fetch_entry(new_entries, id),
           :ok <- validate_target(new_entries, id, source, target),
           :ok <- await_settled(state, source, target, 500) do
        do_move(state, entry, source, target)
      else
        {:error, _reason} -> state
      end
    end)
  end

  # Map of entry id to its immediate parent (`:root` or `{:group, gid}`),
  # over the whole (possibly nested) tree.
  defp locations(entries), do: locations(entries, :root, %{})

  defp locations(entries, parent, acc) do
    Enum.reduce(entries, acc, fn entry, acc ->
      acc = Map.put(acc, entry.id, parent)
      if group?(entry), do: locations(entry.config, {:group, entry.id}, acc), else: acc
    end)
  end

  defp top_entries(state) do
    Enum.map(state.fibers, fn {_id, %{entry: entry}} -> entry end)
  end

  # Where does the entry currently live: at the root or inside a group's
  # child list (possibly nested)? Returns {:ok, entry, :root | {:group, gid}}.
  defp locate(state, id) do
    case Map.fetch(state.fibers, id) do
      {:ok, %{entry: entry}} ->
        {:ok, entry, :root}

      :error ->
        entries = top_entries(state)

        with {:ok, path} <- locate_path(entries, id, []),
             gid <- List.last(path),
             {:ok, group_entry} <- fetch_entry(entries, gid),
             %Entry{} = child <- Enum.find(group_entry.config, &(&1.id == id)) do
          {:ok, child, {:group, gid}}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  # The path of group ids leading to the child list that contains the entry.
  defp locate_path(entries, id, path) do
    if Enum.any?(entries, &(&1.id == id)) do
      {:ok, path}
    else
      entries
      |> Enum.filter(&group?/1)
      |> Enum.reduce_while(:error, fn group_entry, :error ->
        case locate_path(group_entry.config, id, path ++ [group_entry.id]) do
          {:ok, _found} = found -> {:halt, found}
          :error -> {:cont, :error}
        end
      end)
    end
  end

  defp fetch_entry(entries, id) do
    Enum.find_value(entries, :error, fn entry ->
      cond do
        entry.id == id ->
          {:ok, entry}

        group?(entry) ->
          case fetch_entry(entry.config, id) do
            {:ok, _found} = found -> found
            :error -> nil
          end

        true ->
          nil
      end
    end)
  end

  defp group?(%Entry{component: Group, config: config}), do: is_list(config)
  defp group?(%Entry{}), do: false

  defp validate_target(_entries, _id, source, source), do: {:error, :already_there}
  defp validate_target(_entries, _id, _source, :root), do: :ok

  defp validate_target(entries, id, _source, {:group, gid}) do
    path =
      case locate_path(entries, gid, []) do
        {:ok, group_path} -> group_path
        :error -> []
      end

    case fetch_entry(entries, gid) do
      _ when gid == id ->
        {:error, :cannot_move_into_itself}

      :error ->
        {:error, :group_not_found}

      {:ok, target_entry} ->
        cond do
          not group?(target_entry) ->
            {:error, :not_a_group}

          # The target may not live inside the moving entry's own subtree:
          # its containment path would then pass through the entry.
          id in path ->
            {:error, :cannot_move_into_descendant}

          true ->
            :ok
        end
    end
  end

  defp validate_target(_entries, _id, _source, _target), do: {:error, :invalid_target}

  # Moving an entry re-points its parent attribute; if the source or target
  # group fiber is mid-transition, its next diff would misread the transfer.
  # Wait until both are settled before flipping anything.
  defp await_settled(_state, _source, _target, 0), do: {:error, :busy}

  defp await_settled(state, source, target, attempts) do
    pids =
      for location <- [source, target],
          {:group, gid} <- [location],
          {_fiber_id, pid, _attrs} <- [find_fiber(state.ctx.scope, gid)] do
        pid
      end

    if Enum.all?(pids, &settled?/1) do
      :ok
    else
      Process.sleep(10)
      await_settled(state, source, target, attempts - 1)
    end
  end

  defp settled?(pid) do
    status = Fiber.status(pid)
    status.state not in [:loading, :unloading] and not status.updating
  catch
    :exit, _ -> true
  end

  # The live fiber of an entry anywhere in the tree: {fiber_id, pid, attrs}.
  defp find_fiber(scope, id) do
    scope
    |> Store.all_fibers()
    |> Enum.find_value(fn {fiber_id, attrs} ->
      if Map.get(attrs, :entry_id) == id, do: {fiber_id, attrs.pid, attrs}
    end)
  end

  defp do_move(state, entry, source, target) do
    scope = state.ctx.scope

    # Runtime re-parenting: flip the parent attribute, then reassign realms
    # against the new parent (Algorithm 7 inside Isolate.patch).
    case find_fiber(scope, entry.id) do
      nil ->
        # Disabled entry: snapshot-only move.
        :ok

      {fiber_id, pid, _attrs} ->
        {parent_fid, parent_isolate, parent_intercept} = parent_info(state, target)
        Store.update_fiber(scope, fiber_id, %{parent: parent_fid})

        parent_ctx = %{state.ctx | isolate: parent_isolate, intercept: parent_intercept}
        Isolate.patch(parent_ctx, pid, entry, intercept: merged_intercept(parent_ctx, entry))
    end

    # Snapshot rewrite and group convergence: the source group's next diff
    # sees the child gone (and no longer parented to it — hands off), the
    # target group's next diff sees it already parented — adopted as-is.
    state
    |> detach(entry, source)
    |> attach(entry, target)
    |> refresh_group_records(source, target)
  end

  defp parent_info(state, :root) do
    {nil, state.ctx.isolate, state.ctx.intercept}
  end

  defp parent_info(state, {:group, gid}) do
    {fiber_id, _pid, attrs} = find_fiber(state.ctx.scope, gid)
    {fiber_id, Map.get(attrs, :isolate, %{}), Map.get(attrs, :intercept, %{})}
  end

  defp detach(state, entry, :root) do
    %{state | fibers: Map.delete(state.fibers, entry.id)}
  end

  defp detach(state, entry, {:group, gid}) do
    rewrite_group_config(state, gid, fn children ->
      Enum.reject(children, &(&1.id == entry.id))
    end)
  end

  defp attach(state, entry, :root) do
    case find_fiber(state.ctx.scope, entry.id) do
      {_fiber_id, pid, _attrs} ->
        %{state | fibers: Map.put(state.fibers, entry.id, %{entry: entry, pid: pid})}

      nil ->
        state
    end
  end

  defp attach(state, entry, {:group, gid}) do
    rewrite_group_config(state, gid, fn children -> children ++ [entry] end)
  end

  # Rebuild the snapshot, applying fun to the child list of the given group,
  # wherever in the (possibly nested) tree that group entry sits.
  defp rewrite_group_config(state, gid, fun) do
    fibers =
      Map.new(state.fibers, fn {id, %{entry: entry, pid: pid}} ->
        {id, %{entry: rewrite_entry(entry, gid, fun), pid: pid}}
      end)

    %{state | fibers: fibers}
  end

  defp rewrite_entry(%Entry{id: gid, component: Group} = entry, gid, fun) do
    %{entry | config: fun.(entry.config)}
  end

  defp rewrite_entry(%Entry{component: Group, config: config} = entry, gid, fun)
       when is_list(config) do
    %{entry | config: Enum.map(config, &rewrite_entry(&1, gid, fun))}
  end

  defp rewrite_entry(%Entry{} = entry, _gid, _fun), do: entry

  # Deliver the rewritten group configs to the live group fibers, whose
  # keyed child diffs then converge: the moved child is no longer parented
  # to the source group (left alone) and already parented to the target
  # group (adopted in place).
  defp refresh_group_records(state, source, target) do
    entries = top_entries(state)

    for location <- [source, target],
        {:group, gid} <- [location],
        {:ok, group_entry} <- [fetch_entry(entries, gid)],
        {fiber_id, pid, _attrs} <- [find_fiber(state.ctx.scope, gid)] do
      Store.update_fiber(state.ctx.scope, fiber_id, %{entry: group_entry})
      Fiber.reconfigure(pid, group_entry.config)
    end

    state
  end

  ## Internal

  # Refresh the snapshot's entry records from the live fibers, so component
  # write-backs (Context.write_back/2) become the reconcile baseline.
  defp sync_records(state) do
    fibers =
      Map.new(state.fibers, fn {id, %{pid: _pid} = fiber} ->
        case find_fiber(state.ctx.scope, id) do
          {_fiber_id, _pid, %{entry: %Entry{} = recorded}} -> {id, %{fiber | entry: recorded}}
          _ -> {id, fiber}
        end
      end)

    %{state | fibers: fibers}
  end

  defp instantiate_all(ctx, entries) do
    Map.new(entries, fn entry -> {entry.id, spawn(ctx, entry)} end)
    |> Map.reject(fn {_id, fiber} -> is_nil(fiber) end)
  end

  defp spawn(_ctx, %Entry{disabled: true}), do: nil

  defp spawn(ctx, %Entry{} = entry) do
    %{entry: entry, pid: spawn_entry(ctx, entry)}
  end

  # A cooperative change (reconfigure, intercept patch, realm reassignment)
  # only reaches an active, settled fiber; anything else would drop the cast.
  defp active?(pid) do
    Fiber.status(pid).state == :active
  catch
    :exit, _ -> false
  end

  defp rebuild(ctx, pid, entry) do
    Fiber.retire(pid)
    spawn_entry(ctx, entry)
  end

  # The interception metadata an entry runs with: the parent context's,
  # merged with the entry's own annotations (Context.intercept/3 semantics).
  defp merged_intercept(%Context{} = ctx, %Entry{intercept: annotations}) do
    Enum.reduce(annotations, ctx.intercept, fn {key, metadata}, acc ->
      Map.update(acc, key, metadata, &Map.merge(&1, metadata))
    end)
  end

  defp updatable?(component) do
    Code.ensure_loaded?(component) and function_exported?(component, :update, 3)
  end

  defp put_entry_record(scope, pid, entry) do
    Store.update_fiber(scope, Fiber.status(pid).id, %{entry: entry})
  end

  defp apply_annotations(ctx, entry) do
    ctx
    |> then(fn c ->
      Enum.reduce(entry.isolate, c, fn
        {key, annotation}, c -> Context.isolate(c, key, Isolate.realm_for(entry, key, annotation))
      end)
    end)
    |> then(fn c ->
      Enum.reduce(entry.intercept, c, fn {key, metadata}, c ->
        Context.intercept(c, key, metadata)
      end)
    end)
  end
end
