defmodule DexterousHMR.ChangeDetectionTest do
  use ExUnit.Case, async: false

  alias Dexterous.Store
  alias DexterousHMR.TestSupport

  defmodule Probe do
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:test], {:probe_applied, config[:v]})

      Dexterous.Context.effect(ctx, fn _ ->
        fn -> send(config[:test], {:probe_disposed, config[:v]}) end
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

  defp probe(id, v) do
    %DexterousLoader.Entry{id: id, component: Probe, config: [test: self(), v: v]}
  end

  defp group(id, children) do
    %DexterousLoader.Entry{id: id, component: DexterousLoader.Group, config: children}
  end

  test "snapshot/diff spot md5 changes between two loaded versions" do
    {mod, _bin1, _} = TestSupport.compile_and_load(:widget, :v1)
    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    assert %{^mod => %{md5: md5_1}} = before

    # An unrelated loaded module (e.g. a dep) is not watched.
    refute Map.has_key?(before, Enum)

    {_mod, _bin2, _} = TestSupport.compile_and_load(:widget, :v2)
    after_ = DexterousHMR.snapshot([TestSupport.tmp_dir()])
    changed = DexterousHMR.diff(before, after_)

    assert MapSet.member?(changed, mod)
    # The md5 genuinely changed between the two versions.
    assert after_[mod].md5 != md5_1
  end

  test "diff reports modules that appear or vanish" do
    {mod, _bin1, _} = TestSupport.compile_and_load(:widget, :v1)
    before = DexterousHMR.snapshot([TestSupport.tmp_dir()])

    assert MapSet.member?(DexterousHMR.diff(before, %{}), mod)
    assert MapSet.member?(DexterousHMR.diff(%{}, before), mod)
    assert MapSet.size(DexterousHMR.diff(before, before)) == 0
  end

  test "watch_dirs filtering excludes modules outside the tracked dirs" do
    {mod, _bin, _} = TestSupport.compile_and_load(:widget, :v1)
    snapshot = DexterousHMR.snapshot([Path.join(System.tmp_dir!(), "nonexistent_dir")])
    refute Map.has_key?(snapshot, mod)
  end

  test "stale_entries finds live entry fibers whose component changed" do
    ctx = Dexterous.root()

    {:ok, _loader} =
      DexterousLoader.start_link(ctx, [
        probe(:a, 1),
        probe(:b, 1)
      ])

    assert_receive {:probe_applied, 1}
    assert_receive {:probe_applied, 1}

    stale = DexterousHMR.stale_entries(node(), MapSet.new([Probe]))
    assert length(stale) == 2

    # The changed set is a set of module names.
    assert Enum.all?(stale, fn {_fid, _pid, attrs} -> attrs.entry.component == Probe end)

    assert DexterousHMR.stale_entries(node(), MapSet.new([Nonexistent.Module])) == []
  end

  test "topmost keeps only stale entries without a stale ancestor" do
    ctx = Dexterous.root()

    {:ok, _loader} =
      DexterousLoader.start_link(ctx, [
        group(:g, [group(:inner, [probe(:leaf, 1)])]),
        probe(:sibling, 1)
      ])

    assert_receive {:probe_applied, 1}
    assert_receive {:probe_applied, 1}

    # :g and :inner are Group entries, :leaf/:sibling are Probe entries.
    stale =
      DexterousHMR.stale_entries(node(), MapSet.new([DexterousLoader.Group, Probe]))

    top = DexterousHMR.topmost(node(), stale)
    ids = Enum.map(top, fn {_fid, _pid, attrs} -> attrs.entry.id end) |> Enum.sort()

    # :inner lives under :g, :leaf under :inner — both dropped; :sibling kept.
    assert ids == [:g, :sibling]
  end

  test "classify splits accepted from externals and protected" do
    changed = MapSet.new([MyWidget, SomeExternal, Dexterous.Store, Enum])

    {:ok, accepted, refused} =
      DexterousHMR.classify(changed,
        externals: [SomeExternal],
        protected: [MyWidget]
      )

    assert accepted == MapSet.new([Enum])
    assert refused.externals == [SomeExternal]
    assert MapSet.new(refused.protected) == MapSet.new([Dexterous.Store, MyWidget])
  end

  test "classify rejects the batch when an external changes and mode is :reject_batch" do
    changed = MapSet.new([MyWidget, SomeExternal])

    assert {:error, :externals_changed, [SomeExternal]} =
             DexterousHMR.classify(changed, externals: [SomeExternal], externals_mode: :reject_batch)
  end

  test "config resolution: app env defaults, call-level overrides" do
    Application.put_env(:dexterous_hmr, :config,
      externals: [:AppExternal],
      settle_timeout: 1_234,
      rollback: :per_module
    )

    on_exit(fn -> Application.delete_env(:dexterous_hmr, :config) end)

    config = DexterousHMR.config(settle_timeout: 99)

    # App env supplies the defaults...
    assert config[:externals] == [:AppExternal]
    assert config[:rollback] == :per_module
    # ...call-level opts win...
    assert config[:settle_timeout] == 99
    # ...and built-in defaults fill the rest.
    assert config[:watch_dirs] == []
    assert config[:externals_mode] == :continue
  end

  test "protected set includes framework modules and honours allow_reload" do
    changed = MapSet.new([Dexterous.Store, DexterousLoader.Group, MyWidget])

    {:ok, accepted, refused} =
      DexterousHMR.classify(changed, allow_reload: [Dexterous.Store])

    assert accepted == MapSet.new([MyWidget, Dexterous.Store])
    assert refused.protected == [DexterousLoader.Group]
  end
end
