defmodule DexterousTest do
  use ExUnit.Case, async: false

  test "the facade exposes a root context and delegates operations" do
    ctx = Dexterous.root()
    assert :error = Dexterous.get(ctx, :facade_key)
    assert :ok = Dexterous.set(ctx, :facade_key, 1)
    assert {:ok, 1} = Dexterous.get(ctx, :facade_key)

    Dexterous.Store.take_disposers(:root) |> Enum.each(& &1.())
  end
end
