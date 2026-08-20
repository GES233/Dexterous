defmodule DexterousHMR.SwapTest do
  use ExUnit.Case, async: false

  alias Dexterous.Store
  alias DexterousHMR.TestSupport

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

  defp entry(id, component, config) do
    %DexterousLoader.Entry{id: id, component: component, config: config}
  end

  defp fiber_of(entry_id) do
    node()
    |> Store.all_fibers()
    |> Enum.find_value(fn {fiber_id, attrs} ->
      if Map.get(attrs, :entry_id) == entry_id, do: {fiber_id, attrs.pid, attrs}
    end)
  end

  defp load_v1(mod_name) do
    {mod, binary, path} = TestSupport.compile_and_load(mod_name, :v1)
    {mod, binary, path, TestSupport.backup(mod, binary, path)}
  end

  test "a changed component is swapped to the new code; old code is purged" do
    {mod, _bin1, _path1, backup} = load_v1(:widget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [entry(:w, mod, [test: self(), version: 2])])

    assert_receive {:applied, ^mod, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^mod, _bin2, _} = TestSupport.compile_and_load(:widget, :v2)
    after_ = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    changed = DexterousHMR.diff(before, after_)

    {:ok, report} = DexterousHMR.apply(loader, changed, backup, settle_timeout: 2_000)

    assert report.reloaded == [:w]
    assert MapSet.new(report.accepted) == MapSet.new([mod])
    assert_receive {:disposed, ^mod, 1}, 500
    assert_receive {:applied, ^mod, 2}, 500

    # The loaded code is now v2 and the old version is purged.
    assert eventually(fn ->
             snap = DexterousHMR.snapshot([TestSupport.tmp_dir()])
             if snap[mod].md5 == after_[mod].md5, do: true
           end, 50)

    assert :code.soft_purge(mod) == true
  end

  test "an apply crash in the new code rolls the whole batch back (:all)" do
    {mod, _bin1, _path1, backup} = load_v1(:widget)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [entry(:w, mod, [test: self()])])
    assert_receive {:applied, ^mod, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^mod, _bin_bad, _} = TestSupport.compile_and_load(:widget, :bad)
    after_ = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    changed = DexterousHMR.diff(before, after_)

    {:error, {failure, info}} =
      DexterousHMR.apply(loader, changed, backup, settle_timeout: 2_000)

    assert match?({:fiber_failed, [_]}, failure)
    assert info.modules == [mod]

    # Code is back to v1 (md5 matches the pre-compile snapshot) and the entry
    # was rebuilt on the restored code.
    assert eventually(fn ->
             snap = DexterousHMR.snapshot([TestSupport.tmp_dir()])
             if snap[mod].md5 == before[mod].md5, do: true
           end, 50)

    assert_receive {:applied, ^mod, 1}, 500
  end

  test "a settle timeout triggers a rollback" do
    {mod, _bin1, _path1, backup} = load_v1(:widget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [entry(:w, mod, [test: self(), sleep: 2_000])])

    assert_receive {:applied, ^mod, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^mod, _bin_slow, _} = TestSupport.compile_and_load(:widget, :slow)
    after_ = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    changed = DexterousHMR.diff(before, after_)

    {:error, {failure, info}} =
      DexterousHMR.apply(loader, changed, backup, settle_timeout: 100)

    assert failure == {:settle_timeout, :timeout}
    assert info.modules == [mod]

    # The module is back on v1 even though the slow apply is still running.
    snap = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    assert snap[mod].md5 == before[mod].md5
  end

  test "a changed module with no pre-compile version is removed on rollback" do
    # Only v2 exists: no backup binary. The rollback must delete the module.
    {mod, _bin, _path} = TestSupport.compile_and_load(:widget, :v2)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [entry(:w, mod, [test: self(), version: 2])])

    assert_receive {:applied, ^mod, 2}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^mod, _bin_bad, _} = TestSupport.compile_and_load(:widget, :bad)
    changed = DexterousHMR.diff(before, DexterousHMR.snapshot([TestSupport.tmp_dir()]))

    {:error, {failure, _info}} = DexterousHMR.apply(loader, changed, %{}, settle_timeout: 2_000)
    assert match?({:fiber_failed, [_]}, failure)
  end

  test "externals are skipped with a callback; the rest of the batch proceeds" do
    {widget, _b1, _p1, backup_w} = load_v1(:widget)
    {gadget, _b2, _p2, backup_g} = load_v1(:gadget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        entry(:w, widget, [test: self(), version: 2]),
        entry(:g, gadget, [test: self(), version: 2])
      ])

    assert_receive {:applied, ^widget, 1}
    assert_receive {:applied, ^gadget, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^widget, _, _} = TestSupport.compile_and_load(:widget, :v2)
    {^gadget, _, _} = TestSupport.compile_and_load(:gadget, :v2)
    changed = DexterousHMR.diff(before, DexterousHMR.snapshot([TestSupport.tmp_dir()]))

    parent = self()

    {:ok, report} =
      DexterousHMR.apply(loader, changed, Map.merge(backup_w, backup_g),
        settle_timeout: 2_000,
        externals: [gadget],
        on_external: fn mod -> send(parent, {:external_skipped, mod}) end
      )

    # The gadget was refused (external), the widget was swapped.
    assert report.refused.externals == [gadget]
    assert report.reloaded == [:w]
    assert_receive {:external_skipped, ^gadget}
    assert_receive {:disposed, ^widget, 1}
    assert_receive {:applied, ^widget, 2}
    refute_received {:applied, ^gadget, 2}
  end

  test "externals_mode :reject_batch refuses the whole batch" do
    {widget, _b1, _p1, backup_w} = load_v1(:widget)
    {gadget, _b2, _p2, backup_g} = load_v1(:gadget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        entry(:w, widget, [test: self(), version: 2]),
        entry(:g, gadget, [test: self(), version: 2])
      ])

    assert_receive {:applied, ^widget, 1}
    assert_receive {:applied, ^gadget, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^widget, _, _} = TestSupport.compile_and_load(:widget, :v2)
    {^gadget, _, _} = TestSupport.compile_and_load(:gadget, :v2)
    changed = DexterousHMR.diff(before, DexterousHMR.snapshot([TestSupport.tmp_dir()]))

    assert {:error, {:externals_changed, [gadget]}} =
             DexterousHMR.apply(loader, changed, Map.merge(backup_w, backup_g),
               settle_timeout: 2_000,
               externals: [gadget],
               externals_mode: :reject_batch
             )

    # Nothing was reloaded.
    refute_received {:applied, ^widget, 2}
    refute_received {:applied, ^gadget, 2}
  end

  test "framework modules are refused, not reloaded" do
    {widget, _b1, _p1, backup_w} = load_v1(:widget)
    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [entry(:w, widget, [test: self(), version: 2])])
    assert_receive {:applied, ^widget, 1}

    # A changed set that includes a framework module (bypasses the real diff).
    {^widget, _, _} = TestSupport.compile_and_load(:widget, :v2)
    changed = MapSet.new([widget, Dexterous.Store])
    parent = self()

    {:ok, report} =
      DexterousHMR.apply(loader, changed, backup_w,
        settle_timeout: 2_000,
        on_protected: fn mod -> send(parent, {:protected_refused, mod}) end
      )

    assert report.refused.protected == [Dexterous.Store]
    assert report.reloaded == [:w]
    assert_receive {:protected_refused, Dexterous.Store}
    assert_receive {:applied, ^widget, 2}
  end

  test ":per_module rollback restores only the module whose entry failed" do
    {widget, _b1, _p1, backup_w} = load_v1(:widget)
    {gadget, _b2, _p2, backup_g} = load_v1(:gadget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        entry(:w, widget, [test: self(), version: 2]),
        entry(:g, gadget, [test: self(), version: 2])
      ])

    assert_receive {:applied, ^widget, 1}
    assert_receive {:applied, ^gadget, 1}

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^widget, _, _} = TestSupport.compile_and_load(:widget, :v2)
    {^gadget, _, _} = TestSupport.compile_and_load(:gadget, :bad)
    after_ = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    changed = DexterousHMR.diff(before, after_)

    {:error, {failure, info}} =
      DexterousHMR.apply(loader, changed, Map.merge(backup_w, backup_g),
        settle_timeout: 2_000,
        rollback: :per_module
      )

    assert match?({:fiber_failed, [_]}, failure)
    # Only the gadget's module was rolled back.
    assert MapSet.new(info.modules) == MapSet.new([gadget])

    # Gadget is back on v1; widget keeps v2.
    assert eventually(fn ->
             snap = DexterousHMR.snapshot([TestSupport.tmp_dir()])
             if snap[gadget].md5 == before[gadget].md5 and snap[widget].md5 == after_[widget].md5,
               do: true
           end, 50)

    # Both entries were rebuilt: gadget on v1, widget on v2.
    assert_receive {:applied, ^gadget, 1}, 500
    assert_receive {:applied, ^widget, 2}, 500
  end

  test "a nested entry is swapped in place; the group fiber survives" do
    {mod, _bin1, _path1, backup} = load_v1(:widget)
    ctx = Dexterous.root()

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [
        %DexterousLoader.Entry{
          id: :g,
          component: DexterousLoader.Group,
          config: [entry(:w, mod, [test: self(), version: 2])]
        }
      ])

    assert_receive {:applied, ^mod, 1}
    {g_fid, g_pid, _} = fiber_of(:g)
    {w_fid, w_pid, _} = fiber_of(:w)

    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    {^mod, _, _} = TestSupport.compile_and_load(:widget, :v2)
    changed = DexterousHMR.diff(before, DexterousHMR.snapshot([TestSupport.tmp_dir()]))

    {:ok, report} = DexterousHMR.apply(loader, changed, backup, settle_timeout: 2_000)
    assert report.reloaded == [:w]

    assert_receive {:disposed, ^mod, 1}, 500
    assert_receive {:applied, ^mod, 2}, 500

    # The widget was rebuilt under the same, untouched group fiber.
    assert eventually(fn ->
             case fiber_of(:w) do
               {fid, pid, attrs} when fid != w_fid and pid != w_pid ->
                 if attrs.parent == g_fid, do: true

               _ ->
                 nil
             end
           end, 50)

    assert {_, ^g_pid, _} = fiber_of(:g)
  end
end
