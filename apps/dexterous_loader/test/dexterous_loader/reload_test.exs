defmodule DexterousLoader.ReloadTest do
  use ExUnit.Case, async: false

  alias Dexterous.{Context, Store}
  alias DexterousLoader.Entry

  defmodule Probe do
    @moduledoc "Reports apply/dispose with its label and version."
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:probe_applied, config[:label], config[:v]})

      Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:probe_disposed, config[:label], config[:v]}) end
      end)
    end
  end

  defmodule Provider do
    @moduledoc "Provides :shared in the realm the context resolves and reports."
    use Dexterous.Component

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
      send(config[:test], {:consumer_applied, Context.fetch!(ctx, :shared)})
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

  defp group(children, opts \\ []) do
    %Entry{
      id: :g,
      component: DexterousLoader.Group,
      config: children,
      isolate: Keyword.get(opts, :isolate, %{})
    }
  end

  defp fiber_of(entry_id) do
    node()
    |> Store.all_fibers()
    |> Enum.find_value(fn {fiber_id, attrs} ->
      if Map.get(attrs, :entry_id) == entry_id, do: {fiber_id, attrs.pid, attrs}
    end)
  end

  test "reloading a top-level entry swaps its fiber and updates the loader snapshot" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])

    assert_receive {:probe_applied, :a, 1}
    {a_fid, a_pid, _} = fiber_of(:a)
    assert %{pid: ^a_pid} = DexterousLoader.fibers(loader)[:a]
    assert DexterousLoader.scope(loader) == node()

    assert :ok = DexterousLoader.reload_entry(loader, :a)

    assert_receive {:probe_disposed, :a, 1}
    assert_receive {:probe_applied, :a, 1}

    # A fresh fiber, and the loader no longer holds the dead pid.
    assert eventually(fn ->
             case fiber_of(:a) do
               {fid, pid, _} when pid != a_pid and fid != a_fid -> true
               _ -> nil
             end
           end, 50)

    {_new_fid, new_pid, _} = fiber_of(:a)
    assert %{pid: ^new_pid} = DexterousLoader.fibers(loader)[:a]

    # The old fiber is fully gone from the registry.
    assert eventually(fn -> if Store.get_fiber(node(), a_fid) == :error, do: true end, 50)
  end

  test "reloading a nested entry respawns it under the same parent fiber" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [group([probe(:c1, 1), probe(:c2, 1)])])

    assert_receive {:probe_applied, :c1, 1}
    assert_receive {:probe_applied, :c2, 1}

    {g_fid, g_pid, _} = fiber_of(:g)
    {c1_fid, c1_pid, _} = fiber_of(:c1)
    {_c2_fid, c2_pid, _} = fiber_of(:c2)

    assert :ok = DexterousLoader.reload_entry(loader, :c2)

    assert_receive {:probe_disposed, :c2, 1}
    assert_receive {:probe_applied, :c2, 1}

    # The group fiber is untouched; only c2 was rebuilt, re-parented to it.
    assert eventually(fn ->
             case fiber_of(:c2) do
               {_fid, pid, attrs} when pid != c2_pid -> if attrs.parent == g_fid, do: true
               _ -> nil
             end
           end, 50)

    assert {_, ^g_pid, _} = fiber_of(:g)
    assert {^c1_fid, ^c1_pid, _} = fiber_of(:c1)
  end

  test "reload keeps a nested provider in its inherited realm (Algorithm 10 continuity)" do
    ctx = Dexterous.root()
    room = {:global, "room", :shared}

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        group(
          [
            %Entry{id: :p, component: Provider, config: [test: self(), value: 1]},
            %Entry{id: :c, component: Consumer, config: [test: self()]}
          ],
          isolate: %{shared: "room"}
        )
      ])

    assert_receive {:provider_applied, 1}
    assert_receive {:consumer_applied, 1}
    {_p_fid, p_pid, _} = fiber_of(:p)

    assert :ok = DexterousLoader.reload_entry(loader, :p)

    assert_receive {:provider_disposed, 1}, 500
    assert_receive {:provider_applied, 1}, 500

    # The new fiber owns the binding in the very same realm, and the consumer
    # in the room comes back alive on the refreshed binding.
    assert eventually(fn ->
             case fiber_of(:p) do
               {fid, pid, _} when pid != p_pid ->
                 case Store.lookup(node(), room) do
                   {:ok, %{provider: ^fid, value: 1}} -> true
                   _ -> nil
                 end

               _ ->
                 nil
             end
           end, 50)

    assert_receive {:consumer_applied, 1}, 500
  end

  test "reconcile after a reload is a no-op against the live fibers" do
    ctx = Dexterous.root()
    children = [probe(:c1, 1), probe(:c2, 1)]
    {:ok, loader} = DexterousLoader.start_link(ctx, [group(children)])

    assert_receive {:probe_applied, :c1, 1}
    assert_receive {:probe_applied, :c2, 1}

    {g_pid, c1_pid, c2_pid} = pids_of(children)

    assert :ok = DexterousLoader.reload_entry(loader, :c2)
    assert_receive {:probe_disposed, :c2, 1}
    assert_receive {:probe_applied, :c2, 1}

    # Reconciling the identical tree must not rebuild anything: the group's
    # keyed diff adopts the fresh c2 by entry id (old == new).
    :ok = DexterousLoader.reconcile(loader, [group(children)])

    assert eventually(fn ->
             case fiber_of(:c2) do
               {_, pid, _} when pid != c2_pid -> true
               _ -> nil
             end
           end, 50)

    refute_received {:probe_disposed, :c1, _}
    refute_received {:probe_applied, :c1, _}
    refute_received {:probe_disposed, :c2, _}
    refute_received {:probe_applied, :c2, _}

    assert {_, ^g_pid, _} = fiber_of(:g)
    assert {_, ^c1_pid, _} = fiber_of(:c1)
  end

  test "reload_entries reloads several entries in one call" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1), probe(:b, 1)])

    assert_receive {:probe_applied, :a, 1}
    assert_receive {:probe_applied, :b, 1}
    {_, a_pid, _} = fiber_of(:a)
    {_, b_pid, _} = fiber_of(:b)

    assert :ok = DexterousLoader.reload_entries(loader, [:a, :b])

    assert_receive {:probe_disposed, :a, 1}
    assert_receive {:probe_disposed, :b, 1}
    assert_receive {:probe_applied, :a, 1}
    assert_receive {:probe_applied, :b, 1}

    assert eventually(fn ->
             case {fiber_of(:a), fiber_of(:b)} do
               {{_, pa, _}, {_, pb, _}} when pa != a_pid and pb != b_pid -> true
               _ -> nil
             end
           end, 50)
  end

  test "reload of an unknown entry id is refused" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [probe(:a, 1)])
    assert_receive {:probe_applied, :a, 1}

    assert {:error, :not_found} = DexterousLoader.reload_entry(loader, :nope)

    :ok =
      DexterousLoader.reconcile(loader, [%{probe(:a, 1) | disabled: true}])

    assert_receive {:probe_disposed, :a, 1}
    assert eventually(fn -> if is_nil(fiber_of(:a)), do: true end, 50)
    assert {:error, :not_found} = DexterousLoader.reload_entry(loader, :a)
  end

  test "reload of an entry whose parent fiber is gone is refused, not silently re-rooted" do
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [group([probe(:c, 1)])])

    assert_receive {:probe_applied, :c, 1}
    {c_fid, _, _} = fiber_of(:c)

    # Break the parent link out from under the child (white-box: simulates
    # the parent having been retired first). Respawn would lose the child's
    # inherited realms, so the reload must refuse.
    Store.update_fiber(node(), c_fid, %{parent: make_ref()})

    assert {:error, :parent_gone} = DexterousLoader.reload_entry(loader, :c)
  end

  defp pids_of(children) do
    g_pid = elem(fiber_of(:g), 1)
    List.to_tuple([g_pid | Enum.map(children, &elem(fiber_of(&1.id), 1))])
  end
end
