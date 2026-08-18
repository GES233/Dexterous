defmodule DexterousLoader do
  @moduledoc """
  The declarative component loader (paper Section 5.2).

  An orchestrator specifies the desired composition as a list of
  `DexterousLoader.Entry` records; the loader instantiates them as fibers and
  keeps them in step with the specification across `reconcile/2` calls.

  Reconciliation diffs by entry `id`:

    * a new id is instantiated;
    * a vanished id is retired;
    * an id whose entry changed in any other field is rebuilt (retired and
      re-instantiated) — rebuilding is sound: the departing fiber's
      contribution to the state is nothing (paper Corollary 62);
    * a config-only change is handed to the component's `update/3` when it
      exports one;
    * an isolate-only change reassigns the entry's realms in place (paper
      Algorithm 7, `DexterousLoader.Isolate`).

  Nested composition goes through `DexterousLoader.Group`, an ordinary
  component whose config is a list of child entries.
  """

  use GenServer

  alias Dexterous.Context
  alias DexterousLoader.{Entry, Isolate}

  defstruct ctx: nil, fibers: %{}

  ## API

  def start_link(%Context{} = ctx, [%Entry{} | _] = entries) do
    GenServer.start_link(__MODULE__, {ctx, entries})
  end

  @doc "Bring the running composition in step with `entries`."
  def reconcile(loader, entries) do
    GenServer.call(loader, {:reconcile, entries})
  end

  @doc "The currently managed fibers: `%{entry_id => %{entry:, pid:}}`."
  def fibers(loader) do
    GenServer.call(loader, :fibers)
  end

  @doc """
  Instantiate one enabled entry on `ctx`, applying its isolate/intercept
  annotations. Shared by the loader itself and by `DexterousLoader.Group`.
  """
  def spawn_entry(%Context{} = ctx, %Entry{} = entry) do
    child_ctx = apply_annotations(ctx, entry)
    {:ok, pid} = Context.use(child_ctx, entry.component, entry.config)
    pid
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

          %{entry: old, pid: pid} = stale ->
            cond do
              config_only_change?(old, entry) and updatable?(entry.component) ->
                # Paper Section 5.2.1: a config change is handed to the
                # component, which decides how to apply the new payload.
                Dexterous.Fiber.reconfigure(pid, entry.config)
                {id, %{entry: entry, pid: pid}}

              isolate_change?(old, entry) ->
                # Paper Algorithm 7: reassign the entry's realms in place; a
                # config change rides along, absorbed by the forced reload.
                Isolate.patch(state.ctx, pid, entry)
                {id, %{entry: entry, pid: pid}}

              true ->
                Dexterous.Fiber.retire(stale.pid)
                {id, spawn(state.ctx, entry)}
            end

          nil ->
            {id, spawn(state.ctx, entry)}
        end
      end)

    fibers = Map.reject(fibers, fn {_id, fiber} -> is_nil(fiber) end)
    {:reply, :ok, %{state | fibers: fibers}}
  end

  def handle_call(:fibers, _from, state) do
    {:reply, state.fibers, state}
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
