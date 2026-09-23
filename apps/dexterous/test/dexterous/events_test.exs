defmodule Dexterous.EventsTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Events, Store}

  setup do
    :ok = Store.reset(node())
    :ok
  end

  describe "dispatch modes" do
    test "emit runs every listener in registration order and returns :ok" do
      test_pid = self()
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :ping, fn payload -> send(test_pid, {:first, payload}) end)
      {:ok, _} = Context.on(ctx, :ping, fn payload -> send(test_pid, {:second, payload}) end)

      assert :ok = Context.emit(ctx, :ping, 1)
      assert_received {:first, 1}
      assert_received {:second, 1}
    end

    test "serial collects results in registration order" do
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :ping, fn payload -> payload + 1 end)
      {:ok, _} = Context.on(ctx, :ping, fn payload -> payload * 10 end)

      assert [2, 10] = Context.serial(ctx, :ping, 1)
    end

    test "waterfall threads the payload through arity-1 listeners" do
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :munge, fn payload -> payload + 1 end)
      {:ok, _} = Context.on(ctx, :munge, fn payload -> payload * 10 end)

      assert 20 = Context.waterfall(ctx, :munge, 1)
    end

    test "waterfall arity-2 listeners delegate with next" do
      ctx = Context.new()

      {:ok, _} =
        Context.on(ctx, :munge, fn payload, next ->
          # Rewrite on the way in, observe on the way out.
          next.(payload * 2) + 100
        end)

      {:ok, _} = Context.on(ctx, :munge, fn payload -> payload + 1 end)

      assert 103 = Context.waterfall(ctx, :munge, 1)
    end

    test "waterfall short-circuits when a listener declines next" do
      test_pid = self()
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :munge, fn payload, _next -> {:halted, payload} end)
      {:ok, _} = Context.on(ctx, :munge, fn _payload -> send(test_pid, :reached) end)

      assert {:halted, 1} = Context.waterfall(ctx, :munge, 1)
      refute_received :reached
    end

    test "bail takes the first non-nil result and stops" do
      test_pid = self()
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :vote, fn _ -> nil end)
      {:ok, _} = Context.on(ctx, :vote, fn payload -> {:answer, payload} end)
      {:ok, _} = Context.on(ctx, :vote, fn _ -> send(test_pid, :reached) end)

      assert {:answer, 1} = Context.bail(ctx, :vote, 1)
      refute_received :reached
    end

    test "bail returns nil when every listener declines" do
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :vote, fn _ -> nil end)

      assert nil == Context.bail(ctx, :vote, 1)
    end

    test "events on an unheard event are inert" do
      ctx = Context.new()

      assert :ok = Context.emit(ctx, :nothing, 1)
      assert [] = Context.serial(ctx, :nothing, 1)
      assert 1 = Context.waterfall(ctx, :nothing, 1)
      assert nil == Context.bail(ctx, :nothing, 1)
    end
  end

  describe "engine without a context" do
    test "arity-2 listeners get a no-op next outside waterfall" do
      listener = fn payload, next -> next.(payload) + 1 end

      assert [2] = Events.serial([listener], 1)
    end
  end

  describe "effect tracking" do
    test "the returned disposer removes the listener" do
      test_pid = self()
      ctx = Context.new()
      {:ok, disposer} = Context.on(ctx, :ping, fn _ -> send(test_pid, :heard) end)

      disposer.()
      assert :ok = Context.emit(ctx, :ping, 1)
      refute_received :heard
    end

    test "running the owner's disposer stack removes its listeners" do
      test_pid = self()
      ctx = Context.new()
      {:ok, _} = Context.on(ctx, :ping, fn _ -> send(test_pid, :heard) end)

      Store.take_disposers(node(), :root) |> Enum.each(& &1.())
      assert :ok = Context.emit(ctx, :ping, 1)
      refute_received :heard
    end

    test "listeners are scoped" do
      test_pid = self()
      ctx = Context.new()
      other = Context.new(:other_scope)
      {:ok, _} = Context.on(other, :ping, fn _ -> send(test_pid, :other_heard) end)
      {:ok, _} = Context.on(ctx, :ping, fn _ -> send(test_pid, :heard) end)

      assert :ok = Context.emit(ctx, :ping, 1)
      assert_received :heard
      refute_received :other_heard

      Store.reset(:other_scope)
    end
  end
end
