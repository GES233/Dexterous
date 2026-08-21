defmodule DexterousHMR.LoopTest do
  use ExUnit.Case, async: false

  alias Dexterous.Store
  alias DexterousHMR.TestSupport

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    Store.reset(node())

    # One loop server per test, under the default name.
    stop_loop()
    {:ok, _pid} = DexterousHMR.start_link()
    on_exit(fn -> stop_loop() end)
    :ok
  end

  defp stop_loop do
    case Process.whereis(DexterousHMR) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
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

  defp widget_entry(mod) do
    %DexterousLoader.Entry{id: :w, component: mod, config: [test: self(), version: 2]}
  end

  test "register + trigger_compile runs the full pipeline with a stubbed compile" do
    {mod, _bin, _path} = TestSupport.compile_and_load(:widget, :v1)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [widget_entry(mod)])
    assert_receive {:applied, ^mod, 1}
    assert :ok = DexterousHMR.register(loader, [])

    # The stubbed compile loads v2 — the same role Mix compile plays in dev.
    compile_fun = fn ->
      {^mod, _, _} = TestSupport.compile_and_load(:widget, :v2)
      :ok
    end

    {:ok, report} =
      DexterousHMR.trigger_compile(
        watch_dirs: [TestSupport.tmp_dir()],
        compile_fun: compile_fun,
        settle_timeout: 2_000
      )

    assert report.reloaded == [:w]
    assert_receive {:disposed, ^mod, 1}, 500
    assert_receive {:applied, ^mod, 2}, 500

    assert eventually(fn -> if DexterousHMR.status().running == false, do: true end, 50)
    assert DexterousHMR.registered() == %{loader => []}
  end

  test "trigger_compile refuses outside dev unless a compile_fun is configured" do
    assert {:error, :not_dev} = DexterousHMR.trigger_compile(watch_dirs: [])
  end

  test "a cycle with no changes reloads nothing" do
    {mod, _bin, _path} = TestSupport.compile_and_load(:widget, :v1)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [widget_entry(mod)])
    assert_receive {:applied, ^mod, 1}
    assert :ok = DexterousHMR.register(loader, [])

    {:ok, report} =
      DexterousHMR.trigger_compile(
        watch_dirs: [TestSupport.tmp_dir()],
        compile_fun: fn -> :ok end,
        settle_timeout: 2_000
      )

    assert report.reloaded == []
  end

  test "concurrent triggers are coalesced; a queued cycle reruns afterwards" do
    {mod, _bin, _path} = TestSupport.compile_and_load(:widget, :v1)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [widget_entry(mod)])
    assert_receive {:applied, ^mod, 1}
    assert :ok = DexterousHMR.register(loader, [])

    parent = self()

    compile_fun = fn ->
      Process.sleep(300)
      {^mod, _, _} = TestSupport.compile_and_load(:widget, :v2)
      :ok
    end

    opts = [watch_dirs: [TestSupport.tmp_dir()], compile_fun: compile_fun, settle_timeout: 2_000]

    # First trigger in a separate process (it blocks for the cycle).
    spawn(fn -> send(parent, {:t1, DexterousHMR.trigger_compile(opts)}) end)
    assert eventually(fn -> if DexterousHMR.status().running, do: true end, 100)

    # Second trigger while the first cycle runs: coalesced.
    assert {:ok, :queued} = DexterousHMR.trigger_compile(opts)

    # The first caller gets the full report once the cycle completes...
    assert_receive {:t1, {:ok, %{reloaded: [:w]}}}, 3_000

    # ...then the queued rerun executes (nothing changed: no reloads).
    assert eventually(fn -> if DexterousHMR.status().running == false, do: true end, 200)
    assert {:ok, %{reloaded: []}} = DexterousHMR.trigger_compile(opts)
  end

  test "the :watcher option closes the file-change → HMR loop without host wiring" do
    {mod, _bin, _path} = TestSupport.compile_and_load(:watched_widget, :v1)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [widget_entry(mod)])
    assert_receive {:applied, ^mod, 1}

    compile_fun = fn ->
      {^mod, _, _} = TestSupport.compile_and_load(:watched_widget, :v2)
      :ok
    end

    # Replace the loop from setup with one owning a watcher.
    stop_loop()

    {:ok, _pid} =
      DexterousHMR.start_link(
        watcher: [dirs: [TestSupport.tmp_dir()], interval: 50, debounce: 50],
        watch_dirs: [TestSupport.tmp_dir()],
        compile_fun: compile_fun,
        settle_timeout: 2_000
      )

    assert :ok = DexterousHMR.register(loader, [])

    # A file change under the watched dir triggers a cycle on its own.
    File.write!(
      Path.join(TestSupport.tmp_dir(), "trigger_#{System.unique_integer([:positive])}.ex"),
      "# touched\n"
    )

    assert_receive {:applied, ^mod, 2}, 3_000
  end

  test "unregister removes a loader from the cycle" do
    {mod, _bin, _path} = TestSupport.compile_and_load(:widget, :v1)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [widget_entry(mod)])
    assert_receive {:applied, ^mod, 1}

    assert :ok = DexterousHMR.register(loader, [])
    assert :ok = DexterousHMR.unregister(loader)
    assert DexterousHMR.registered() == %{}
  end
end
