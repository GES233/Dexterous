defmodule DexterousLoader.MoveTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Store}
  alias DexterousLoader.Entry

  defmodule Provider do
    @moduledoc "Provides :shared and reports its lifecycle."
    use Dexterous.Component, provide: [:shared]

    @impl true
    def apply(ctx, config) do
      Context.set(ctx, :shared, config[:value])
      send(config[:test], {:provider_applied, config[:value]})

      Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:provider_disposed, config[:value]}) end
      end)
    end
  end

  defmodule Consumer do
    @moduledoc "Injects :shared and reports what it resolved to."
    use Dexterous.Component, inject: [:shared]

    @impl true
    def apply(ctx, config) do
      value = Context.fetch!(ctx, :shared)
      send(config[:test], {:consumer_applied, value})
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

  defp provider(id, value) do
    %Entry{id: id, component: Provider, config: [test: self(), value: value]}
  end

  defp group(id, children, isolate) do
    %Entry{id: id, component: DexterousLoader.Group, config: children, isolate: isolate}
  end

  defp fiber_of(entry_id) do
    node()
    |> Store.all_fibers()
    |> Enum.find_value(fn {fiber_id, attrs} ->
      if Map.get(attrs, :entry_id) == entry_id, do: {fiber_id, attrs.pid, attrs}
    end)
  end

  test "reconcile detects a relocation and moves the fiber instead of rebuilding" do
    ctx = Dexterous.root()

    tree = fn holder ->
      [
        group(:a, if(holder == :a, do: [provider(:p, 1)], else: []), %{}),
        group(:b, if(holder == :b, do: [provider(:p, 1)], else: []), %{})
      ]
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, tree.(:a))
    assert_receive {:provider_applied, 1}
    {p_fid, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.reconcile(loader, tree.(:b))

    # The fiber kept its identity and was re-parented to :b — no rebuild.
    assert {^p_fid, ^p_pid, attrs} = fiber_of(:p)
    {b_fid, _, _} = fiber_of(:b)
    assert attrs.parent == b_fid
    refute_received {:provider_disposed, _}
    refute_received {:provider_applied, _}

    # A later reconcile with the same tree is a no-op.
    assert :ok = DexterousLoader.reconcile(loader, tree.(:b))
    assert {^p_fid, ^p_pid, _} = fiber_of(:p)
  end

  test "reconciling a relocation back to the root moves the fiber too" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [group(:a, [provider(:p, 1)], %{})])

    assert_receive {:provider_applied, 1}
    {p_fid, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.reconcile(loader, [group(:a, [], %{}), provider(:p, 1)])

    assert {^p_fid, ^p_pid, attrs} = fiber_of(:p)
    assert attrs.parent == nil
    refute_received {:provider_disposed, _}
    refute_received {:provider_applied, _}
  end

  test "moving an entry between groups preserves its fiber" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(:a, [provider(:p, 1)], %{}),
        group(:b, [], %{})
      ])

    assert_receive {:provider_applied, 1}
    {p_fid, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.move(loader, :p, {:group, :b})

    # Same fiber, re-pointed at the target group.
    assert {^p_fid, ^p_pid, attrs} = fiber_of(:p)
    {b_fid, _, _} = fiber_of(:b)
    assert attrs.parent == b_fid

    # No realm changed, so the fiber was not even reloaded.
    refute_received {:provider_disposed, _}
    refute_received {:provider_applied, _}

    # Its binding never went away.
    assert {:ok, %{value: 1, provider: ^p_fid}} = Store.lookup(node(), :shared)
  end

  test "moving an entry into an isolated group reassigns its realms (Algorithm 7)" do
    ctx = Dexterous.root()
    room_b = {:global, "roomB", :shared}

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(:a, [provider(:p, 1)], %{}),
        group(:b, [%Entry{id: :c, component: Consumer, config: [test: self()]}], %{shared: "roomB"})
      ])

    # The consumer resolves :shared in roomB, where nothing is provided yet.
    refute_received {:consumer_applied, _}
    assert_receive {:provider_applied, 1}
    {p_fid, p_pid, _} = fiber_of(:p)
    assert {:ok, %{provider: ^p_fid}} = Store.lookup(node(), :shared)

    assert :ok = DexterousLoader.move(loader, :p, {:group, :b})

    # The binding was the entry's own: it traveled to roomB, still owned by
    # the same fiber, and the consumer in roomB came alive.
    assert_receive {:provider_disposed, 1}, 500
    assert_receive {:provider_applied, 1}, 500
    assert_receive {:consumer_applied, 1}, 500

    assert {^p_fid, ^p_pid, _} = fiber_of(:p)

    assert settled(fn ->
             case {Store.lookup(node(), :shared), Store.lookup(node(), room_b)} do
               {:error, {:ok, %{value: 1, provider: ^p_fid}}} -> true
               _ -> nil
             end
           end)
  end

  test "moving an entry to the root and back preserves it" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        provider(:p, 1),
        group(:b, [], %{})
      ])

    assert_receive {:provider_applied, 1}
    {p_fid, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.move(loader, :p, {:group, :b})
    refute Map.has_key?(DexterousLoader.fibers(loader), :p)

    assert :ok = DexterousLoader.move(loader, :p, :root)
    assert %{entry: %Entry{id: :p}, pid: ^p_pid} = DexterousLoader.fibers(loader)[:p]

    assert {^p_fid, ^p_pid, attrs} = fiber_of(:p)
    assert attrs.parent == nil
    refute_received {:provider_disposed, _}
  end

  test "reconcile after a move is a no-op against the rewritten snapshot" do
    ctx = Dexterous.root()
    p = provider(:p, 1)

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(:a, [p], %{}),
        group(:b, [], %{})
      ])

    assert_receive {:provider_applied, 1}

    assert :ok = DexterousLoader.move(loader, :p, {:group, :b})

    # The desired tree matching the post-move state reconciles to nothing.
    :ok =
      DexterousLoader.reconcile(loader, [
        group(:a, [], %{}),
        group(:b, [p], %{})
      ])

    {p_fid, p_pid, _} = fiber_of(:p)
    assert settled(fn -> if fiber_of(:p), do: true end)
    assert {^p_fid, ^p_pid, _} = fiber_of(:p)
    refute_received {:provider_disposed, _}
    refute_received {:provider_applied, _}
  end

  test "moving a whole group carries its subtree along" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(:outer, [group(:inner, [provider(:p, 1)], %{})], %{}),
        group(:b, [], %{})
      ])

    assert_receive {:provider_applied, 1}
    {_, inner_pid, _} = fiber_of(:inner)
    {_, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.move(loader, :inner, {:group, :b})

    # Neither the moved group nor its child was rebuilt; the child still
    # points at the moved group, which now points at its new parent.
    assert {inner_fid, ^inner_pid, inner_attrs} = fiber_of(:inner)
    assert {_, ^p_pid, p_attrs} = fiber_of(:p)
    assert p_attrs.parent == inner_fid
    {b_fid, _, _} = fiber_of(:b)
    assert inner_attrs.parent == b_fid

    refute_received {:provider_disposed, _}
    assert {:ok, %{value: 1}} = Store.lookup(node(), :shared)
  end

  test "move validates its arguments" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(:a, [provider(:p, 1)], %{})
      ])

    assert_receive {:provider_applied, 1}

    assert {:error, :not_found} = DexterousLoader.move(loader, :nope, {:group, :a})
    assert {:error, :group_not_found} = DexterousLoader.move(loader, :p, {:group, :nope})
    assert {:error, :cannot_move_into_itself} = DexterousLoader.move(loader, :a, {:group, :a})

    # Nested descendant check: moving :a into a group inside :a.
    :ok =
      DexterousLoader.reconcile(loader, [
        group(:a, [provider(:p, 1), group(:sub, [], %{})], %{})
      ])

    assert settled(fn -> if fiber_of(:sub), do: true end)
    assert {:error, :cannot_move_into_descendant} = DexterousLoader.move(loader, :a, {:group, :sub})
    assert {:error, :already_there} = DexterousLoader.move(loader, :p, {:group, :a})
  end
end
