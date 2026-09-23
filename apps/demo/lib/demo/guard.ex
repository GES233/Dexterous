defmodule Demo.Guard do
  @moduledoc """
  Intercepts the `:"demo/tick"` waterfall event the clock emits per tick,
  shifting every tick number by `config[:offset]` before subscribers see it.

  The listener is registered with `Dexterous.Context.on/3`, a revertible
  effect: unloading this component removes the interception automatically.
  """

  use Dexterous.Component

  @impl true
  def apply(ctx, config) do
    offset = config[:offset] || 0

    Dexterous.Context.on(ctx, :"demo/tick", fn n, next ->
      next.(n + offset)
    end)
  end
end
