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
  test "get/2 applies an intercept :transform to the stored value" do
    ctx = Context.new() |> Context.intercept(:theme, %{transform: &String.upcase/1})
    :ok = Context.set(ctx, :theme, "dark")

    assert {:ok, "DARK"} = Context.get(ctx, :theme)
    # A context without the interceptor sees the raw value.
    assert {:ok, "dark"} = Context.get(Context.new(), :theme)
  end

  test "intercept metadata is merged and child layers take priority" do
    parent = Context.new() |> Context.intercept(:svc, %{a: 1, b: 2})
    child = Context.intercept(parent, :svc, %{b: 3, c: 4})

    assert Context.intercept_for(parent, :svc) == %{a: 1, b: 2}
    assert Context.intercept_for(child, :svc) == %{a: 1, b: 3, c: 4}
  end

  test "effect/3 with guard halts when the guard returns false" do
    ctx = Context.new()
    test_pid = self()

    allow = fn -> Process.get(:allow_effect, true) end
    {:ok, _} = Context.effect(ctx, fn _ -> fn -> send(test_pid, :a_disposed) end end, guard: allow)

    Process.put(:allow_effect, false)

    assert_raise Dexterous.HaltedError, fn ->
      Context.effect(ctx, fn _ -> fn -> send(test_pid, :b_disposed) end end, guard: allow)
    end

    # Only the first inverse is on the stack.
    [disposer] = Store.take_disposers(node(), :root)
    disposer.()
    assert_received :a_disposed
    refute_received :b_disposed
  after
    Process.delete(:allow_effect)
  end

  test "effect/3 uses the context's guard when none is supplied" do
    ctx = %{Context.new() | guard: fn -> false end}

    assert_raise Dexterous.HaltedError, fn ->
      Context.effect(ctx, fn _ -> fn -> :ok end end)
    end
  end

  test "provide/3 installs a binding computed from the interception metadata" do
    ctx = Context.new()
    :ok = Context.provide(ctx, :fs, fn meta -> Map.get(meta, :mode, :read) end)

    # The empty metadata εₖ applies by default.
    assert {:ok, :read} = Context.get(ctx, :fs)

    write = Context.intercept(ctx, :fs, %{mode: :write})
    assert {:ok, :write} = Context.get(write, :fs)
    # The parent context is untouched.
    assert {:ok, :read} = Context.get(ctx, :fs)
  end

  test "metadata merge is right-biased with MapSet union (the ⊕ₖ monoid)" do
    base = %{mode: :read, paths: MapSet.new(["/a"]), note: 1}
    overlay = %{mode: :write, paths: MapSet.new(["/b"])}

    assert Context.merge_metadata(base, overlay) == %{
             mode: :write,
             paths: MapSet.new(["/a", "/b"]),
             note: 1
           }

    parent = Context.intercept(Context.new(), :fs, %{paths: MapSet.new(["/a"])})
    child = Context.intercept(parent, :fs, %{paths: MapSet.new(["/b"])})
    assert Context.intercept_for(child, :fs) == %{paths: MapSet.new(["/a", "/b"])}
  end

  test "effect/3 iterates {inverse, continuation} steps, recovering LIFO" do
    ctx = Context.new()
    test_pid = self()

    build = fn build, list ->
      case list do
        [] -> :done
        [step | rest] -> {fn -> send(test_pid, {:disposed, step}) end, fn -> build.(build, rest) end}
      end
    end

    {:ok, _last} = Context.effect(ctx, fn _ -> build.(build, [1, 2, 3]) end)

    # Each step pushed its own inverse; recovery unwinds LIFO.
    Store.take_disposers(node(), :root) |> Enum.each(& &1.())
    assert_received {:disposed, 3}
    assert_received {:disposed, 2}
    assert_received {:disposed, 1}
  end

  test "an iterator halts at the boundary where the guard turns false" do
    ctx = Context.new()
    test_pid = self()
    allow = fn -> Process.get(:allow_effect, true) end

    build = fn build, list ->
      case list do
        [] -> :done
        [step | rest] -> {fn -> send(test_pid, {:disposed, step}) end, fn -> build.(build, rest) end}
      end
    end

    callback = fn _ctx ->
      Process.put(:allow_effect, false)
      build.(build, [1, 2])
    end

    assert_raise Dexterous.HaltedError, fn ->
      Context.effect(ctx, callback, guard: allow)
    end

    # The first step was recorded before the halt; the second never ran.
    [disposer] = Store.take_disposers(node(), :root)
    disposer.()
    assert_received {:disposed, 1}
    refute_received {:disposed, 2}
  after
    Process.delete(:allow_effect)
  end
end
