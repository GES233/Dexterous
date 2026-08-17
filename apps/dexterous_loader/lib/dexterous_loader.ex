defmodule DexterousLoader do
  @moduledoc """
  The declarative component loader (paper Section 5.2).

  An orchestrator specifies the desired composition as a list of
  `DexterousLoader.Entry` records; the loader instantiates them as fibers and
  keeps them in step with the specification across `reconcile/2` calls.

  Reconciliation diffs by entry `id`:

    * a new id is instantiated;
    * a vanished id is retired;
    * an id whose entry changed in any field is rebuilt (retired and
      re-instantiated) — the least disruptive operation for a `config` change
      is the component's own concern, and rebuilding is sound: the departing
      fiber's contribution to the state is nothing (paper Corollary 62).

  Nested composition goes through `DexterousLoader.Group`, an ordinary
  component whose config is a list of child entries.
  """

  use GenServer

  alias Dexterous.Context
  alias DexterousLoader.Entry

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
            if config_only_change?(old, entry) and updatable?(entry.component) do
              # Paper Section 5.2.1: a config change is handed to the
              # component, which decides how to apply the new payload.
              Dexterous.Fiber.reconfigure(pid, entry.config)
              {id, %{entry: entry, pid: pid}}
            else
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

  defp updatable?(component) do
    Code.ensure_loaded?(component) and function_exported?(component, :update, 3)
  end

  defp apply_annotations(ctx, entry) do
    ctx
    |> then(fn c ->
      Enum.reduce(entry.isolate, c, fn
        {key, true}, c -> Context.isolate(c, key)
        {key, name}, c when is_binary(name) -> Context.isolate(c, key, {:global, name})
      end)
    end)
    |> then(fn c ->
      Enum.reduce(entry.intercept, c, fn {key, metadata}, c ->
        Context.intercept(c, key, metadata)
      end)
    end)
  end
end
