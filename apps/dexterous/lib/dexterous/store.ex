defmodule Dexterous.Store do
  @moduledoc """
  Owns the ETS tables that back the context paradigm.

  Tables are partitioned by *scope*: each scope gets its own triple of

    * `store` — coeffect bindings, `{realm, entry}` where entry is
      `%{key:, value:, provider:}` (provider is a fiber id or `nil` for root)
    * `fibers` — live fibers, `{fiber_id, attrs}`
    * `disposers` — per-owner stacks of revertible-effect inverses (LIFO),
      keyed by fiber id or `:root`

  The default scope is the node name (`node/0`); `Dexterous.root/1` starts an
  independent composition root under an explicit scope name, so several
  applications can share one VM without seeing each other's bindings.

  Tables are `:public` and looked up through the `:dexterous_scopes` meta
  table; the GenServer only owns them so they survive as long as the
  application does.
  """

  use GenServer

  @scopes :dexterous_scopes

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@scopes, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure, scope}, _from, state) do
    {:reply, ensure_tables(scope), state}
  end

  ## Bindings

  def bind(scope, realm, entry) when is_map(entry) do
    :ets.insert(store(scope), {realm, entry})
    :ok
  end

  def unbind(scope, realm) do
    :ets.delete(store(scope), realm)
    :ok
  end

  def lookup(scope, realm) do
    case :ets.lookup(store(scope), realm) do
      [{^realm, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  ## Fibers

  def register_fiber(scope, id, attrs) when is_map(attrs) do
    :ets.insert(fibers(scope), {id, attrs})
    :ok
  end

  def update_fiber(scope, id, attrs) when is_map(attrs) do
    table = fibers(scope)

    case :ets.lookup(table, id) do
      [{^id, old}] -> :ets.insert(table, {id, Map.merge(old, attrs)})
      [] -> :ok
    end

    :ok
  end

  def delete_fiber(scope, id) do
    :ets.delete(fibers(scope), id)
    :ok
  end

  def get_fiber(scope, id) do
    case :ets.lookup(fibers(scope), id) do
      [{^id, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  def all_fibers(scope) do
    scope
    |> fibers()
    |> :ets.tab2list()
    |> Map.new()
  end

  @doc "Keys whose current binding was installed by the given fiber."
  def keys_provided_by(scope, fiber_id) do
    scope
    |> store()
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_realm, %{provider: ^fiber_id, key: key}} -> [key]
      _ -> []
    end)
  end

  ## Disposer stacks (revertible-effect accumulators)

  @doc "Push an inverse onto the owner's stack. Stacks run LIFO on recovery."
  def push_disposer(scope, owner, fun) when is_function(fun, 0) do
    table = disposers(scope)

    stack =
      case :ets.lookup(table, owner) do
        [{^owner, stack}] -> stack
        [] -> []
      end

    :ets.insert(table, {owner, [fun | stack]})
    :ok
  end

  @doc "Atomically take the owner's whole stack (LIFO order), leaving it empty."
  def take_disposers(scope, owner) do
    case :ets.take(disposers(scope), owner) do
      [{^owner, stack}] -> stack
      [] -> []
    end
  end

  @doc "Drop every table of a scope. Intended for tests."
  def reset(scope) do
    {store, fibers, disposers} = tids(scope)
    :ets.delete_all_objects(store)
    :ets.delete_all_objects(fibers)
    :ets.delete_all_objects(disposers)
    :ok
  end

  ## Internal

  defp store(scope), do: elem(tids(scope), 0)
  defp fibers(scope), do: elem(tids(scope), 1)
  defp disposers(scope), do: elem(tids(scope), 2)

  defp tids(scope) do
    case :ets.lookup(@scopes, scope) do
      [{^scope, tids}] -> tids
      [] -> GenServer.call(__MODULE__, {:ensure, scope})
    end
  end

  defp ensure_tables(scope) do
    case :ets.lookup(@scopes, scope) do
      [{^scope, tids}] ->
        tids

      [] ->
        tids = {
          :ets.new(:store, [:public, :set]),
          :ets.new(:fibers, [:public, :set]),
          :ets.new(:disposers, [:public, :set])
        }

        :ets.insert(@scopes, {scope, tids})
        tids
    end
  end
end
