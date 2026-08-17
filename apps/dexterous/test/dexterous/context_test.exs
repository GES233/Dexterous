defmodule Dexterous.ContextTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Store}

  setup do
    # Each test starts from a clean store.
    :ok = Store.reset(node())
    :ok
  end

  test "set/get roundtrip on the root context" do
    ctx = Context.new()
    assert :error = Context.get(ctx, :theme)
    assert :ok = Context.set(ctx, :theme, "dark")
    assert {:ok, "dark"} = Context.get(ctx, :theme)
  end

  test "unloading the owner recovers the binding" do
    ctx = Context.new()
    :ok = Context.set(ctx, :theme, "dark")

    [disposer] = Store.take_disposers(node(), :root)
    disposer.()

    assert :error = Context.get(ctx, :theme)
  end

  test "inverses run LIFO" do
    ctx = Context.new()
    test_pid = self()

    {:ok, _} = Context.effect(ctx, fn _ -> fn -> send(test_pid, {:disposed, 1}) end end)
    {:ok, _} = Context.effect(ctx, fn _ -> fn -> send(test_pid, {:disposed, 2}) end end)

    Store.take_disposers(node(), :root) |> Enum.each(& &1.())

    assert_received {:disposed, 2}
    assert_received {:disposed, 1}
  end

  test "a disposer fires at most once" do
    ctx = Context.new()
    test_pid = self()
    {:ok, disposer} = Context.effect(ctx, fn _ -> fn -> send(test_pid, :fired) end end)

    disposer.()
    disposer.()

    assert_received :fired
    refute_received :fired
  end

  test "isolated contexts resolve a key to independent bindings" do
    ctx = Context.new()
    child = Context.isolate(ctx, :database)

    :ok = Context.set(ctx, :database, :primary)
    assert {:ok, :primary} = Context.get(ctx, :database)
    assert :error = Context.get(child, :database)

    :ok = Context.set(child, :database, :replica)
    assert {:ok, :replica} = Context.get(child, :database)
    assert {:ok, :primary} = Context.get(ctx, :database)
  end

  test "explicit realms are shared by contexts naming them" do
    ctx = Context.new()
    alice = Context.isolate(ctx, :database, :shared_realm)
    bob = Context.isolate(ctx, :database, :shared_realm)

    :ok = Context.set(alice, :database, :replica)
    assert {:ok, :replica} = Context.get(bob, :database)
  end

  test "intercept merges metadata with priority to the newer layer" do
    ctx = Context.new() |> Context.intercept(:database, %{timeout: 1000, readonly: false})
    child = Context.intercept(ctx, :database, %{readonly: true})

    assert ctx.intercept[:database] == %{timeout: 1000, readonly: false}
    assert child.intercept[:database] == %{timeout: 1000, readonly: true}
  end

  test "scopes partition the store" do
    on_exit(fn -> Store.reset(:other_scope) end)

    a = Context.new()
    b = Context.new(:other_scope)

    :ok = Context.set(a, :theme, "dark")
    assert {:ok, "dark"} = Context.get(a, :theme)
    assert :error = Context.get(b, :theme)

    :ok = Context.set(b, :theme, "light")
    assert {:ok, "dark"} = Context.get(a, :theme)
    assert {:ok, "light"} = Context.get(b, :theme)
  end

  test "track/2 stops the process when the owner unloads" do
    ctx = Context.new()
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    {:ok, _disposer} = Context.track(ctx, agent)

    Store.take_disposers(node(), :root) |> Enum.each(& &1.())
    refute Process.alive?(agent)
  end

  test "track/2 tolerates an already-dead process" do
    ctx = Context.new()
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    {:ok, disposer} = Context.track(ctx, agent)
    Agent.stop(agent)

    assert :ok = disposer.()
  end
end
