defmodule DexterousLoader.IsolateTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Fiber, Store}
  alias DexterousLoader.Entry

  defmodule Provider do
    @moduledoc "Provides the configured key with the configured value."
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      Context.set(ctx, config[:key], config[:value])
    end
  end

  defmodule Consumer do
    @moduledoc "Injects :shared and reports what it resolved to."
    use Dexterous.Component, inject: [:shared]

    @impl true
    def apply(ctx, config) do
      test = config[:test]
      value = Context.fetch!(ctx, :shared)
      Context.effect(ctx, fn _ -> fn -> send(test, {:consumer_disposed, value}) end end)
      send(test, {:consumer_applied, value})
    end
  end

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    Store.reset(node())
    :ok
  end

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        if attempts > 0 do
          Process.sleep(10)
          eventually(fun, attempts - 1)
        end

      result ->
        result
    end
  end

  defp settled(fun), do: eventually(fun, 50)

  defp provider(id, key, value, isolate) do
    %Entry{id: id, component: Provider, config: [key: key, value: value], isolate: isolate}
  end

  defp consumer(id, isolate) do
    %Entry{id: id, component: Consumer, config: [test: self()], isolate: isolate}
  end

  test "an isolate change reassigns realms in place and moves the owned binding" do
    ctx = Dexterous.root()
    s1 = {:global, "room1", :shared}
    s2 = {:global, "room2", :shared}

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        provider(:p, :shared, 1, %{shared: "room1"}),
        consumer(:c, %{shared: "room1"})
      ])

    assert_receive {:consumer_applied, 1}
    pid_p = DexterousLoader.fibers(loader)[:p].pid
    pid_c = DexterousLoader.fibers(loader)[:c].pid

    :ok = DexterousLoader.reconcile(loader, [
      provider(:p, :shared, 1, %{shared: "room2"}),
      consumer(:c, %{shared: "room1"})
    ])

    # The entry is patched in place: same fiber, and its binding traveled to
    # the new realm without going away in between (the move is synchronous
    # with the reconcile call).
    assert DexterousLoader.fibers(loader)[:p].pid == pid_p
    assert :error = Store.lookup(node(), s1)
    assert {:ok, %{value: 1, provider: provider_id}} = Store.lookup(node(), s2)
    assert provider_id == Fiber.status(pid_p).id

    # The consumer left behind in the old realm loses the binding and unloads.
    assert_receive {:consumer_disposed, 1}, 500

    assert settled(fn ->
             if Fiber.status(pid_c).state == :inactive, do: true
           end)
  end

  test "a dependent re-patched to the new realm follows the binding" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        provider(:p, :shared, 1, %{shared: "room1"}),
        consumer(:c, %{shared: "room1"})
      ])

    assert_receive {:consumer_applied, 1}
    pid_c = DexterousLoader.fibers(loader)[:c].pid

    :ok = DexterousLoader.reconcile(loader, [
      provider(:p, :shared, 1, %{shared: "room2"}),
      consumer(:c, %{shared: "room1"})
    ])

    assert_receive {:consumer_disposed, 1}, 500

    :ok = DexterousLoader.reconcile(loader, [
      provider(:p, :shared, 1, %{shared: "room2"}),
      consumer(:c, %{shared: "room2"})
    ])

    # The consumer reloads in place against the new realm and sees the value.
    assert_receive {:consumer_applied, 1}, 500
    assert DexterousLoader.fibers(loader)[:c].pid == pid_c

    assert settled(fn ->
             if Fiber.status(pid_c).state == :active, do: true
           end)
  end

  test "a binding the entry does not own stays in the old realm" do
    ctx = Dexterous.root()
    :ok = Context.set(ctx, :shared, 9)

    {:ok, loader} = DexterousLoader.start_link(ctx, [consumer(:c, %{})])
    assert_receive {:consumer_applied, 9}
    pid_c = DexterousLoader.fibers(loader)[:c].pid

    :ok = DexterousLoader.reconcile(loader, [consumer(:c, %{shared: "room"})])

    # The root binding is not the entry's own: untouched, and nothing appears
    # at the new realm until someone provides there.
    assert {:ok, %{value: 9, provider: nil}} = Store.lookup(node(), :shared)
    assert :error = Store.lookup(node(), {:global, "room", :shared})

    # The patched fiber kept its identity and waits inactive at the new realm.
    assert DexterousLoader.fibers(loader)[:c].pid == pid_c
    assert_receive {:consumer_disposed, 9}, 500

    assert settled(fn ->
             if Fiber.status(pid_c).state == :inactive, do: true
           end)
  end

  test "a config change rides along with the isolate patch" do
    ctx = Dexterous.root()
    s2 = {:global, "room2", :shared}

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [provider(:p, :shared, 1, %{shared: "room1"})])

    assert settled(fn ->
             case Store.lookup(node(), {:global, "room1", :shared}) do
               {:ok, %{value: 1}} -> true
               _ -> nil
             end
           end)

    pid_p = DexterousLoader.fibers(loader)[:p].pid
    :ok = DexterousLoader.reconcile(loader, [provider(:p, :shared, 2, %{shared: "room2"})])

    # The forced reload absorbs the new config: the binding at the new realm
    # ends up with the new value, installed by the same fiber.
    assert DexterousLoader.fibers(loader)[:p].pid == pid_p

    assert settled(fn ->
             case Store.lookup(node(), s2) do
               {:ok, %{value: 2, provider: provider_id}} ->
                 if provider_id == Fiber.status(pid_p).id, do: true

               _ ->
                 nil
             end
           end)
  end

  test "a binding provided inside the entry's subtree is carried along" do
    ctx = Dexterous.root()
    s1 = {:global, "room1", :shared}
    s2 = {:global, "room2", :shared}
    child = provider(:p, :shared, 1, %{})

    group = fn room ->
      %Entry{
        id: :g,
        component: DexterousLoader.Group,
        config: [child],
        isolate: %{shared: room}
      }
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [group.("room1")])

    assert settled(fn ->
             case Store.lookup(node(), s1) do
               {:ok, %{value: 1}} -> true
               _ -> nil
             end
           end)

    pid_g = DexterousLoader.fibers(loader)[:g].pid
    :ok = DexterousLoader.reconcile(loader, [group.("room2")])

    # The provider sits in a child fiber of the group's subtree; the delimiter
    # walk up the parent chain still proves the binding own, so it moves.
    assert DexterousLoader.fibers(loader)[:g].pid == pid_g

    assert settled(fn ->
             case {Store.lookup(node(), s1), Store.lookup(node(), s2)} do
               {:error, {:ok, %{value: 1}}} -> true
               _ -> nil
             end
           end)
  end

  test "isolate: true selects a local realm tagged by the entry id" do
    ctx = Dexterous.root()

    {:ok, _loader} =
      DexterousLoader.start_link(ctx, [provider(:p, :shared, 1, %{shared: true})])

    assert settled(fn ->
             case Store.lookup(node(), {:local, :p, :shared}) do
               {:ok, %{value: 1}} -> true
               _ -> nil
             end
           end)
  end
end
