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
    use Dexterous.Component, provide: [:shared]

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

  defmodule Updatable do
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:updatable_applied, config[:label]})

      Dexterous.Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:updatable_disposed, config[:label]}) end
      end)
    end

    @impl true
    def update(_ctx, old, new) do
      send(new[:test], {:updated, old[:label], new[:label]})
      if new[:reload], do: :reload, else: :ok
    end
  end

  defmodule Reader do
    @moduledoc "Injects :shared and reads it on apply and on update."
    use Dexterous.Component, inject: [:shared]

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:reader_applied, Dexterous.Context.fetch!(ctx, :shared)})
    end

    @impl true
    def update(ctx, _old, new) do
      send(new[:test], {:reader_updated, Dexterous.Context.fetch!(ctx, :shared)})
      :ok
    end
  end

  defmodule Fragile do
    @moduledoc "Fails in apply when configured to."
    use Dexterous.Component

    @impl true
    def apply(_ctx, config) do
      if config[:fail], do: raise("boom")
      send(config[:test], {:fragile_applied, config[:label]})
    end

    @impl true
    def update(_ctx, _old, _new), do: :ok
  end

  defmodule SelfTuning do
    @moduledoc "Revises its own config and writes it back to its entry."
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      if config[:tune] do
        Dexterous.Context.write_back(ctx, fn entry ->
          %{entry | config: entry.config |> Keyword.put(:label, :tuned) |> Keyword.put(:tune, false)}
        end)
      end

      send(config[:test], {:tuner_applied, config[:label]})
    end
  end

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    Dexterous.Store.reset(node())
    :ok
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
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

  test "a config change on a component without update/3 rebuilds the entry" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])
    assert_receive {:probe_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [probe(:a, 2)])
    assert_receive {:probe_disposed, 1}
    assert_receive {:probe_applied, 2}
  end

  test "a config-only change is handed to update/3 without a rebuild" do
    ctx = Dexterous.root()

    entry = fn label ->
      %Entry{id: :u, component: Updatable, config: [test: self(), label: label]}
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [entry.(1)])
    assert_receive {:updatable_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [entry.(2)])
    assert_receive {:updated, 1, 2}
    refute_received {:updatable_disposed, _}
    refute_received {:updatable_applied, _}
  end

  test "update/3 may ask for an in-place reload" do
    ctx = Dexterous.root()

    entry = fn label, reload ->
      %Entry{id: :u, component: Updatable, config: [test: self(), label: label, reload: reload]}
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [entry.(1, false)])
    assert_receive {:updatable_applied, 1}

    :ok = DexterousLoader.reconcile(loader, [entry.(2, true)])
    assert_receive {:updated, 1, 2}
    assert_receive {:updatable_disposed, 1}
    assert_receive {:updatable_applied, 2}
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

  test "a group config change rebuilds the children whose entries changed" do
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

  test "an intercept-only change updates the fiber in place, without a reload" do
    ctx = Dexterous.root()
    :ok = Dexterous.Context.set(ctx, :shared, "abc")

    entry = fn transform ->
      %Entry{
        id: :r,
        component: Reader,
        config: [test: self()],
        intercept: %{shared: %{transform: transform}}
      }
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [entry.(&String.upcase/1)])
    assert_receive {:reader_applied, "ABC"}
    pid = DexterousLoader.fibers(loader)[:r].pid

    :ok = DexterousLoader.reconcile(loader, [entry.(&String.reverse/1)])

    # No reload happened: same fiber, no apply/dispose, and the entry record
    # and fiber metadata were updated in place.
    assert DexterousLoader.fibers(loader)[:r].pid == pid
    refute_received {:reader_applied, _}
    fiber_id = Dexterous.Fiber.status(pid).id
    {:ok, attrs} = Dexterous.Store.get_fiber(node(), fiber_id)
    assert attrs.entry.intercept[:shared].transform.("ab") == "ba"
    assert attrs.intercept[:shared].transform.("ab") == "ba"

    # A later config change goes to update/3, which reads with the new metadata.
    :ok =
      DexterousLoader.reconcile(loader, [
        %Entry{
          id: :r,
          component: Reader,
          config: [test: self(), v: 2],
          intercept: %{shared: %{transform: &String.reverse/1}}
        }
      ])

    assert_receive {:reader_updated, "cba"}
    refute_received {:reader_applied, _}
  end

  test "a config change on a failed fiber rebuilds it instead of dropping the change" do
    ctx = Dexterous.root()
    entry = fn label, fail ->
      %Entry{id: :f, component: Fragile, config: [test: self(), label: label, fail: fail]}
    end

    {:ok, loader} = DexterousLoader.start_link(ctx, [entry.(1, true)])
    pid = DexterousLoader.fibers(loader)[:f].pid

    assert eventually(fn ->
             status = Dexterous.Fiber.status(pid)
             if status.state == :failed, do: status
           end)

    :ok = DexterousLoader.reconcile(loader, [entry.(2, false)])

    # The fiber was rebuilt with the new config rather than left failed with
    # the snapshot silently advanced past it.
    assert_receive {:fragile_applied, 2}
    new_pid = DexterousLoader.fibers(loader)[:f].pid
    assert new_pid != pid

    assert eventually(fn ->
             status = Dexterous.Fiber.status(new_pid)
             if status.state == :active, do: status
           end)
  end

  test "a component write-back is adopted by reload and reconcile" do
    ctx = Dexterous.root()

    entry = %Entry{
      id: :t,
      component: SelfTuning,
      config: [test: self(), label: 1, tune: true]
    }

    {:ok, loader} = DexterousLoader.start_link(ctx, [entry])
    assert_receive {:tuner_applied, 1}

    # The entry record carries the revision.
    {_fiber_id, _pid, attrs} =
      Dexterous.Store.all_fibers(node())
      |> Enum.find_value(fn {fid, a} -> if a[:entry_id] == :t, do: {fid, a.pid, a} end)

    assert attrs.entry.config[:label] == :tuned

    # An in-place reload respawns from the revised record.
    :ok = DexterousLoader.reload_entry(loader, :t)
    assert_receive {:tuner_applied, :tuned}
  end
end
