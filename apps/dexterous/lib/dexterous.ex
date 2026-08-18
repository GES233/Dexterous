defmodule Dexterous do
  @moduledoc """
  Dexterous — an Elixir implementation of the spatiotemporal composability
  paradigm (revertible effects + reactive coeffects).

    * Temporal composability: every mutation of the shared context flows
      through `Dexterous.Context.effect/3`, which tracks an inverse; unloading
      a component recovers the environment in LIFO order.
    * Spatial composability: components declare their dependencies
      (`inject/0`) and are notified and re-evaluated whenever a binding they
      depend on changes.

  ## Example

      ctx = Dexterous.root()
      {:ok, _service} = Dexterous.use(ctx, MyService, [])
      {:ok, _consumer} = Dexterous.use(ctx, MyConsumer, [])
  """

  alias Dexterous.Context

  @doc """
  The root context, not owned by any fiber. `scope` defaults to the node
  name; pass an explicit name for an independent composition root in the
  same VM.
  """
  def root(scope \\ node()), do: Context.new(scope)

  defdelegate get(ctx, key), to: Context
  defdelegate fetch!(ctx, key), to: Context
  defdelegate set(ctx, key, value), to: Context
  defdelegate isolate(ctx, key), to: Context
  defdelegate isolate(ctx, key, realm), to: Context
  defdelegate intercept(ctx, key, metadata), to: Context
  defdelegate intercept_for(ctx, key), to: Context
  defdelegate effect(ctx, callback), to: Context
  defdelegate effect(ctx, callback, opts), to: Context
  defdelegate track(ctx, pid), to: Context
  defdelegate track(ctx, pid, reason), to: Context
  defdelegate use(ctx, component, config), to: Context
  defdelegate notify(ctx, keys), to: Context
end
