defmodule Dexterous.Store do
  @moduledoc """
  Owns the shared ETS tables that back the context paradigm:

    * `:dexterous_store` — coeffect bindings, `{realm, entry}` where entry is
      `%{key:, value:, provider:}` (provider is a fiber id or `nil` for root)
    * `:dexterous_fibers` — live fibers, `{fiber_id, attrs}`
    * `:dexterous_disposers` — per-owner stacks of revertible-effect inverses
      (LIFO), keyed by fiber id or `:root`

  Tables are `:public`; the GenServer only owns them so they survive as long
  as the application does.
  """

  use GenServer

  @store :dexterous_store
  @fibers :dexterous_fibers
  @disposers :dexterous_disposers

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@store, [:named_table, :public, :set])
    :ets.new(@fibers, [:named_table, :public, :set])
    :ets.new(@disposers, [:named_table, :public, :set])
    {:ok, %{}}
  end

  ## Bindings

  def bind(realm, entry) when is_map(entry) do
    :ets.insert(@store, {realm, entry})
    :ok
  end

  def unbind(realm) do
    :ets.delete(@store, realm)
    :ok
  end

  def lookup(realm) do
    case :ets.lookup(@store, realm) do
      [{^realm, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  ## Fibers

  def register_fiber(id, attrs) when is_map(attrs) do
    :ets.insert(@fibers, {id, attrs})
    :ok
  end

  def update_fiber(id, attrs) when is_map(attrs) do
    case :ets.lookup(@fibers, id) do
      [{^id, old}] -> :ets.insert(@fibers, {id, Map.merge(old, attrs)})
      [] -> :ok
    end

    :ok
  end

  def delete_fiber(id) do
    :ets.delete(@fibers, id)
    :ok
  end

  def get_fiber(id) do
    case :ets.lookup(@fibers, id) do
      [{^id, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  def all_fibers do
    @fibers
    |> :ets.tab2list()
    |> Map.new()
  end

  @doc "Keys whose current binding was installed by the given fiber."
  def keys_provided_by(fiber_id) do
    @store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_realm, %{provider: ^fiber_id, key: key}} -> [key]
      _ -> []
    end)
  end

  ## Disposer stacks (revertible-effect accumulators)

  @doc "Push an inverse onto the owner's stack. Stacks run LIFO on recovery."
  def push_disposer(owner, fun) when is_function(fun, 0) do
    stack =
      case :ets.lookup(@disposers, owner) do
        [{^owner, stack}] -> stack
        [] -> []
      end

    :ets.insert(@disposers, {owner, [fun | stack]})
    :ok
  end

  @doc "Atomically take the owner's whole stack (LIFO order), leaving it empty."
  def take_disposers(owner) do
    case :ets.take(@disposers, owner) do
      [{^owner, stack}] -> stack
      [] -> []
    end
  end
end
