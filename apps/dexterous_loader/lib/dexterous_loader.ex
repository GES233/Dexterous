defmodule DexterousLoader do
  @moduledoc """
  The declarative component loader (paper Section 5.2).

  An orchestrator specifies the desired composition as a list of
  `DexterousLoader.Entry` records; the loader instantiates them as fibers and
  keeps them in step with the specification across `reconcile/2` calls.

  Reconciliation diffs by entry `id`:

    * a new id is instantiated;
    * a vanished id is retired;
    * a config-only change is handed to the component's `update/3` when it
      exports one (paper Section 5.2.1);
    * an isolate-only change reassigns the entry's realms in place (paper
      Algorithm 7, `DexterousLoader.Isolate`);
    * any other change rebuilds the entry (retired and re-instantiated) —
      rebuilding is sound: the departing fiber's contribution to the state is
      nothing (paper Corollary 62).

  Nested composition goes through `DexterousLoader.Group`, an ordinary
  component whose config is a list of child entries; its config changes are
  applied as a keyed diff over child ids, so reconciliation recurses down
  the tree without rebuilding surviving subtrees.

  `move/3` relocates an entry to another group (or the root) while keeping
  its fiber — the equivalent of cordis's `EntryTree.update(id, opts, parent)`.
  Entry ids must be unique across the whole tree within a scope, since moves
  and child bookkeeping identify fibers by entry id.
  """

  use GenServer

  alias Dexterous.{Context, Fiber, Store}
  alias DexterousLoader.{Entry, Group, Isolate}

  defstruct ctx: nil, fibers: %{}

  ## API

  def start_link(%Context{} = ctx, [%Entry{} | _] = entries) do
    GenServer.start_link(__MODULE__, {ctx, entries})
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

  Relocating an entry by editing group configs and reconciling remains
  delete + recreate; use this function when identity matters. Returns
  `:ok` or `{:error, reason}`.
  """
  def move(loader, id, target) do
    GenServer.call(loader, {:move, id, target})
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
  def reconcile_child(%Context{} = ctx, %Entry{} = old, %Entry{} = new, pid) do
    cond do
      new.disabled ->
        Fiber.retire(pid)
        nil

      old == new ->
        pid

      config_only_change?(old, new) and updatable?(new.component) ->
        # Paper Section 5.2.1: a config change is handed to the component,
        # which decides how to apply the new payload.
        Fiber.reconfigure(pid, new.config)
        put_entry_record(ctx.scope, pid, new)
        pid

      isolate_change?(old, new) ->
        # Paper Algorithm 7: reassign the entry's realms in place; a config
        # change rides along, absorbed by the forced reload.
        Isolate.patch(ctx, pid, new)
        pid

      true ->
        Fiber.retire(pid)
        spawn_entry(ctx, new)
    end
  end

  ## GenServer callbacks

  @impl true
  def init({ctx, entries}) do
    {:ok, %__MODULE__{ctx: ctx, fibers: instantiate_all(ctx, entries)}}
  end

  @impl true
  def handle_call({:reconcile, entries}, _from, state) do
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

  def handle_call(:fibers, _from, state) do
    {:reply, state.fibers, state}
  end

  ## Internal: moves

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
        Isolate.patch(parent_ctx, pid, entry, intercept: merge_intercept(parent_intercept, entry))
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

  # The interception metadata the entry inherits at its new parent: the
  # parent's map, merged with the entry's own annotations (Context.intercept/3
  # semantics).
  defp merge_intercept(parent_intercept, %Entry{intercept: annotations}) do
    Enum.reduce(annotations, parent_intercept, fn {key, metadata}, acc ->
      Map.update(acc, key, metadata, &Map.merge(&1, metadata))
    end)
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

  defp instantiate_all(ctx, entries) do
    Map.new(entries, fn entry -> {entry.id, spawn(ctx, entry)} end)
    |> Map.reject(fn {_id, fiber} -> is_nil(fiber) end)
  end

  defp spawn(_ctx, %Entry{disabled: true}), do: nil

  defp spawn(ctx, %Entry{} = entry) do
    %{entry: entry, pid: spawn_entry(ctx, entry)}
  end

  # Everything but the payload is identical: identity, component, realm and
  # interception annotations, and the disabled flag.
  defp config_only_change?(old, new) do
    old.component == new.component and old.isolate == new.isolate and
      old.intercept == new.intercept and old.disabled == new.disabled and
      old.config != new.config
  end

  # Identity, component, interception annotations and the disabled flag are
  # all unchanged, but the realm annotations moved: reassign realms in place
  # instead of rebuilding. A config change alongside is absorbed by the
  # reload the reassignment forces.
  defp isolate_change?(old, new) do
    old.component == new.component and old.intercept == new.intercept and
      old.disabled == new.disabled and not new.disabled and old.isolate != new.isolate
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
