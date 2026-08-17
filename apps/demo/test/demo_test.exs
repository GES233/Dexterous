defmodule DemoTest do
  use ExUnit.Case, async: false

  alias DexterousLoader.Entry

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    Dexterous.Store.reset(node())
    :ok
  end

  defp clock(interval),
    do: %Entry{id: :clock, component: Demo.Clock, config: [interval: interval]}

  defp reporter(every),
    do: %Entry{id: :reporter, component: Demo.Reporter, config: [every: every, target: self()]}

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

  test "reporter waits for the clock, then ticks" do
    {:ok, loader} = DexterousLoader.start_link(Dexterous.root(), [reporter(1)])
    refute_received {:report, _}

    :ok = DexterousLoader.reconcile(loader, [reporter(1), clock(20)])
    assert_receive {:report, 0}
    assert_receive {:report, 1}
  end

  test "update/3 absorbs a new `every` in place, without restarting the loop" do
    {:ok, loader} =
      DexterousLoader.start_link(Dexterous.root(), [reporter(100), clock(30)])

    assert_receive {:report, 0}
    # every = 100: no further reports without an update.
    refute_received {:report, _}

    :ok = DexterousLoader.reconcile(loader, [reporter(1), clock(30)])
    # With the update absorbed, the very next tick is reported.
    assert_receive {:report, n} when n > 0
  end

  test "disabling the clock takes the reporter down with it" do
    {:ok, loader} =
      DexterousLoader.start_link(Dexterous.root(), [reporter(1), clock(20)])

    assert_receive {:report, 0}
    reporter_pid = DexterousLoader.fibers(loader).reporter.pid
    mon = Process.monitor(reporter_pid)

    :ok = DexterousLoader.reconcile(loader, [reporter(1), %{clock(20) | disabled: true}])

    # The reporter is drained (still alive but inactive), not killed.
    assert eventually(fn ->
             if Dexterous.Fiber.status(reporter_pid).state == :inactive, do: true
           end)

    refute_received {:DOWN, ^mon, :process, ^reporter_pid, _}
    refute_received {:report, _}
  end

  test "a replaced clock resubscribes the reporter against the new provider" do
    {:ok, loader} =
      DexterousLoader.start_link(Dexterous.root(), [reporter(1), clock(30)])

    assert_receive {:report, 0}

    # Remove and re-add: a new fiber with a fresh uid provides :clock.
    :ok = DexterousLoader.reconcile(loader, [reporter(1)])
    refute_received {:report, _}

    :ok = DexterousLoader.reconcile(loader, [reporter(1), clock(30)])
    assert_receive {:report, 0}

    fibers = DexterousLoader.fibers(loader)
    assert Dexterous.Fiber.status(fibers.reporter.pid).state == :active
  end
end
