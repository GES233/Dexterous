defmodule DexterousLoader.GroupTest do
  use ExUnit.Case, async: false

  alias Dexterous.Store
  alias DexterousLoader.Entry

  defmodule Probe do
    @moduledoc "Reports apply/dispose with its label and version."
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:probe_applied, config[:label], config[:v]})

      Dexterous.Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:probe_disposed, config[:label], config[:v]}) end
      end)
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

  defp probe(id, v) do
    %Entry{id: id, component: Probe, config: [test: self(), label: id, v: v]}
  end

  defp group(children), do: %Entry{id: :g, component: DexterousLoader.Group, config: children}

  defp fiber_of(entry_id) do
    node()
    |> Store.all_fibers()
    |> Enum.find_value(fn {fiber_id, attrs} ->
      if Map.get(attrs, :entry_id) == entry_id, do: {fiber_id, attrs.pid, attrs}
    end)
  end

  test "a group config change applies a keyed diff: survivors keep their fibers" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [group([probe(:c1, 1), probe(:c2, 1)])])

    assert_receive {:probe_applied, :c1, 1}
    assert_receive {:probe_applied, :c2, 1}

    {_, group_pid, _} = fiber_of(:g)
    {_, c1_pid, _} = fiber_of(:c1)
    {_, c2_pid, _} = fiber_of(:c2)

    # Only c2's config changes; c1 is untouched by the diff.
    :ok = DexterousLoader.reconcile(loader, [group([probe(:c1, 1), probe(:c2, 2)])])

    assert_receive {:probe_disposed, :c2, 1}, 500
    assert_receive {:probe_applied, :c2, 2}, 500
    refute_received {:probe_disposed, :c1, _}
    refute_received {:probe_applied, :c1, _}

    # Neither the group fiber nor the surviving child's fiber was rebuilt.
    assert {_, ^group_pid, _} = fiber_of(:g)
    assert {_, ^c1_pid, _} = fiber_of(:c1)
    assert {_, new_c2_pid, _} = fiber_of(:c2)
    assert new_c2_pid != c2_pid
  end

  test "the keyed diff retires removed children and spawns added ones only" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [group([probe(:c1, 1), probe(:c2, 1)])])

    assert_receive {:probe_applied, :c1, 1}
    assert_receive {:probe_applied, :c2, 1}

    {_, c2_pid, _} = fiber_of(:c2)

    :ok = DexterousLoader.reconcile(loader, [group([probe(:c2, 1), probe(:c3, 1)])])

    assert_receive {:probe_disposed, :c1, 1}, 500
    assert_receive {:probe_applied, :c3, 1}, 500
    refute_received {:probe_disposed, :c2, _}
    refute_received {:probe_applied, :c2, _}

    assert eventually(fn -> if is_nil(fiber_of(:c1)), do: true end, 50)
    assert {_, ^c2_pid, _} = fiber_of(:c2)
    assert {_, _, _} = fiber_of(:c3)
  end

  test "a child disabled by the diff is retired; re-enabling spawns it afresh" do
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [group([probe(:c1, 1), probe(:c2, 1)])])

    assert_receive {:probe_applied, :c1, 1}
    assert_receive {:probe_applied, :c2, 1}

    :ok =
      DexterousLoader.reconcile(loader, [
        group([probe(:c1, 1), %{probe(:c2, 1) | disabled: true}])
      ])

    assert_receive {:probe_disposed, :c2, 1}, 500
    refute_received {:probe_disposed, :c1, _}
    assert eventually(fn -> if is_nil(fiber_of(:c2)), do: true end, 50)

    :ok = DexterousLoader.reconcile(loader, [group([probe(:c1, 1), probe(:c2, 1)])])
    assert_receive {:probe_applied, :c2, 1}, 500
  end
end
