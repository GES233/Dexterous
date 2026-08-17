defmodule Dexterous.FiberTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Fiber}

  defmodule Service do
    @moduledoc "Provides the :service coeffect with its configured value."
    def inject, do: []

    def apply(ctx, config) do
      test = config[:test]
      Context.set(ctx, :service, config[:value])
      Context.effect(ctx, fn _ -> fn -> send(test, {:service_disposed, config[:value]}) end end)
      send(test, {:service_applied, config[:value]})
    end
  end

  defmodule Consumer do
    @moduledoc "Injects :service and reports what it resolved to."

    def inject, do: [:service]

    def apply(ctx, config) do
      test = config[:test]
      value = Context.fetch!(ctx, :service)
      Context.effect(ctx, fn _ -> fn -> send(test, {:consumer_disposed, value}) end end)
      send(test, {:consumer_applied, value})
    end
  end

  defmodule BadFetch do
    @moduledoc "Accesses a coeffect it never declared."
    use Dexterous.Component

    @impl true
    def apply(ctx, _config) do
      Context.fetch!(ctx, :nope)
    end
  end

  defmodule Bad do
    @moduledoc "Registers an effect and then raises."
    def inject, do: []

    def apply(ctx, config) do
      Context.effect(ctx, fn _ -> fn -> send(config[:test], :bad_partial_disposed) end end)
      raise "boom"
    end
  end

  defmodule Child do
    def inject, do: []

    def apply(ctx, config) do
      Context.effect(ctx, fn _ -> fn -> send(config[:test], :child_disposed) end end)
    end
  end

  defmodule Parent do
    def inject, do: []

    def apply(ctx, config) do
      {:ok, child} = Context.use(ctx, Child, test: config[:test])
      send(config[:test], {:child_pid, child})
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

  test "a fiber waits inactive until its coeffects are provided" do
    ctx = Context.new()
    {:ok, consumer} = Context.use(ctx, Consumer, test: self())
    assert %{state: :inactive} = Fiber.status(consumer)
    refute_received {:consumer_applied, _}

    {:ok, _service} = Context.use(ctx, Service, test: self(), value: 1)
    assert_receive {:service_applied, 1}
    assert_receive {:consumer_applied, 1}
    assert %{state: :active, target: %{service: _provider}} = Fiber.status(consumer)
  end

  test "unloading a provider drains its dependents first, then recovers LIFO" do
    ctx = Context.new()
    {:ok, service} = Context.use(ctx, Service, test: self(), value: 1)
    {:ok, consumer} = Context.use(ctx, Consumer, test: self())
    assert_receive {:consumer_applied, 1}

    mon = Process.monitor(service)
    Fiber.retire(service)

    # The dependent is fully disposed before the provider's inverses run.
    assert_receive {:consumer_disposed, 1}
    assert %{state: :inactive} = Fiber.status(consumer)
    assert_receive {:service_disposed, 1}
    assert_receive {:DOWN, ^mon, :process, ^service, :normal}
  end

  test "replacing a provider reloads the dependent against the new provider" do
    ctx = Context.new()
    {:ok, service_a} = Context.use(ctx, Service, test: self(), value: :a)
    {:ok, _consumer} = Context.use(ctx, Consumer, test: self())
    assert_receive {:consumer_applied, :a}

    Fiber.retire(service_a)
    assert_receive {:consumer_disposed, :a}

    {:ok, _service_b} = Context.use(ctx, Service, test: self(), value: :b)
    assert_receive {:consumer_applied, :b}
  end

  test "a fiber whose apply raises ends up failed, with partial effects recovered" do
    ctx = Context.new()
    {:ok, bad} = Context.use(ctx, Bad, test: self())

    assert_receive :bad_partial_disposed
    assert %{state: :failed} = Fiber.status(bad)
  end

  test "unloading a parent cascades to its children" do
    ctx = Context.new()
    {:ok, parent} = Context.use(ctx, Parent, test: self())
    assert_receive {:child_pid, child}
    mon = Process.monitor(child)

    Fiber.retire(parent)

    assert_receive :child_disposed
    assert_receive {:DOWN, ^mon, :process, ^child, :normal}
  end

  test "fetch! authorizes access against the committed view" do
    ctx = Context.new()
    {:ok, _service} = Context.use(ctx, Service, test: self(), value: 42)
    {:ok, _consumer} = Context.use(ctx, Consumer, test: self())
    assert_receive {:consumer_applied, 42}
  end

  test "fetch! on an undeclared key fails the fiber with UndeclaredAccessError" do
    ctx = Context.new()
    {:ok, bad} = Context.use(ctx, BadFetch, [])

    assert %{state: :failed, last_error: {%Dexterous.UndeclaredAccessError{key: :nope}, _}} =
             eventually(fn -> if Fiber.status(bad).state == :failed, do: Fiber.status(bad) end)
  end

  test "fetch! on a declared but uncommitted key raises InactiveAccessError" do
    ctx = Context.new()
    {:ok, consumer} = Context.use(ctx, Consumer, test: self())
    assert %{state: :inactive, id: id} = Fiber.status(consumer)

    stale_ctx = %Context{fiber: id}

    assert_raise Dexterous.InactiveAccessError, fn ->
      Context.fetch!(stale_ctx, :service)
    end
  end

  test "a late unbind does not wipe out a replacement binding" do
    ctx = Context.new()
    {:ok, service_a} = Context.use(ctx, Service, test: self(), value: :a)
    assert_receive {:service_applied, :a}
    {:ok, service_b} = Context.use(ctx, Service, test: self(), value: :b)
    assert_receive {:service_applied, :b}

    # A's unload finishes after B has rebound the same realm.
    Fiber.retire(service_a)
    assert_receive {:service_disposed, :a}

    assert {:ok, :b} = Context.get(ctx, :service)
    assert %{state: :active} = Fiber.status(service_b)
  end

  test "use Dexterous.Component declares the coeffect specification" do
    assert BadFetch.inject() == []
    assert Consumer.inject() == [:service]
  end
end
