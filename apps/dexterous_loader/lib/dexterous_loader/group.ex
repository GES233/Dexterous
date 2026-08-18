defmodule DexterousLoader.Group do
  @moduledoc """
  A component that loads a list of child entries as a subgroup (the paper's
  `@cordisjs/group`).

  It is an ordinary component resting on the core's registration primitive:
  children are instantiated with `Dexterous.Context.use/3`, so unloading the
  group cascades to them. When the group's config changes, the change is
  handed to `update/3`, which applies a keyed diff over child ids (paper
  Section 5.2.1): surviving children keep their fibers and are reconciled
  per-field (`DexterousLoader.reconcile_child/4`), removed children are
  retired, new children are spawned.

  A child whose fiber was moved elsewhere by `DexterousLoader.move/3` is
  recognized by its parent attribute and left alone; symmetrically, a fiber
  moved *into* this group is adopted in place.
  """

  use Dexterous.Component

  alias Dexterous.{Context, Fiber, Store}

  @impl true
  def apply(%Context{} = ctx, entries) do
    reconcile_children(ctx, entries)
  end

  @impl true
  def update(%Context{} = ctx, _old_entries, new_entries) do
    reconcile_children(ctx, new_entries)
    :ok
  end

  ## Internal

  # Keyed diff over child ids against the group's live child fibers.
  defp reconcile_children(%Context{} = ctx, entries) do
    children = child_fibers(ctx.scope, ctx.fiber)
    new_by_id = Map.new(entries, &{&1.id, &1})

    # Retire children that vanished from the list. (A child moved elsewhere
    # is no longer parented to this fiber, so it is absent from the scan
    # already — nothing to hand off here.)
    for {id, {_fiber_id, pid, _entry}} <- children, not Map.has_key?(new_by_id, id) do
      Fiber.retire(pid)
    end

    for {id, entry} <- new_by_id do
      case children[id] do
        {_fiber_id, pid, %DexterousLoader.Entry{} = old} ->
          DexterousLoader.reconcile_child(ctx, old, entry, pid)

        _no_live_child ->
          unless entry.disabled, do: DexterousLoader.spawn_entry(ctx, entry)
      end
    end

    :ok
  end

  # The group's live child fibers: loader-spawned fibers (they carry an
  # entry id) whose parent attribute points at this fiber. Returns a map of
  # entry id to {fiber_id, pid, entry}.
  defp child_fibers(scope, parent_id) do
    scope
    |> Store.all_fibers()
    |> Enum.flat_map(fn
      {fiber_id, %{parent: ^parent_id, entry_id: entry_id} = attrs} when not is_nil(entry_id) ->
        [{entry_id, {fiber_id, attrs.pid, Map.get(attrs, :entry)}}]

      {_fiber_id, _attrs} ->
        []
    end)
    |> Map.new()
  end
end
