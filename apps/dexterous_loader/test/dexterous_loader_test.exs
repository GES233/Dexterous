defmodule DexterousLoaderTest do
  use ExUnit.Case, async: false

  alias DexterousLoader.Entry

  defmodule Probe do
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:probe_applied, config[:label]})

      Dexterous.Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:probe_disposed, config[:label]}) end
      end)
    end
  end

  defmodule Provider do
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      Dexterous.Context.set(ctx, config[:key], config[:value])
    end
  end

  defmodule SharedConsumer do
    use Dexterous.Component, inject: [:shared]

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:shared_applied, Dexterous.Context.fetch!(ctx, :shared)})
    end
  end

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    :ets.delete_all_objects(:dexterous_store)
    :ets.delete_all_objects(:dexterous_fibers)
    :ets.delete_all_objects(:dexterous_disposers)
    :ok
  end

  defp probe(id, label, opts \\ []) do
    %Entry{
      id: id,
      component: Probe,
      config: [test: self(), label: label],
      disabled: Keyword.get(opts, :disabled, false)
    }
  end

  test "load instantiates enabled entries and skips disabled ones" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1), probe(:b, 2, disabled: true)])

    assert_receive {:probe_applied, 1}
    refute_received {:probe_applied, 2}

    fibers = DexterousLoader.fibers(loader)
    assert Map.has_key?(fibers, :a)
    refute Map.has_key?(fibers, :b)
  end

  test "reconcile adds new entries and retires vanished ones" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])
    assert_receive {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:a, 1), probe(:b, 2)])
    assert_receive {:probe_applied, 2}
    refute_received {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:b, 2)])
    assert_receive {:probe_disposed, 1}
    refute_received {:probe_disposed, 2}
  end

  test "reconcile rebuilds an entry whose config changed" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])
    assert_receive {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:a, 2)])
    assert_receive {:probe_disposed, 1}
    assert_receive {:probe_applied, 2}
  end

  test "reconcile honors the disabled flag" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])
    assert_receive {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:a, 1, disabled: true)])
    assert_receive {:probe_disposed, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:a, 1)])
    assert_receive {:probe_applied, 1}
  end

  test "a group loads its child entries and rebuilds the subtree on config change" do
    ctx = Dexterous.root()

    group = fn label ->
      %Entry{
        id: :g,
        component: DexterousLoader.Group,
        config: [probe(:c1, label), probe(:c2, label)]
      }
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [group.(1)])
    assert_receive {:probe_applied, 1}
    assert_receive {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [group.(2)])
    assert_receive {:probe_disposed, 1}
    assert_receive {:probe_disposed, 1}
    assert_receive {:probe_applied, 2}
    assert_receive {:probe_applied, 2}
  end

  test "isolate: true gives an entry a private realm" do
    ctx = Dexterous.root()

    entries = [
      %Entry{
        id: :p,
        component: Provider,
        config: [key: :shared, value: 1],
        isolate: %{shared: true}
      },
      %Entry{id: :c, component: SharedConsumer, config: [test: self()]}
    ]

    {:ok, _loader} = DexterousLoader.start_link(ctx, entries)
    refute_received {:shared_applied, _}
  end

  test "isolate with a string shares a named global realm" do
    ctx = Dexterous.root()

    entries = [
      %Entry{
        id: :p,
        component: Provider,
        config: [key: :shared, value: 7],
        isolate: %{shared: "room"}
      },
      %Entry{
        id: :c,
        component: SharedConsumer,
        config: [test: self()],
        isolate: %{shared: "room"}
      }
    ]

    {:ok, _loader} = DexterousLoader.start_link(ctx, entries)
    assert_receive {:shared_applied, 7}
  end
end
