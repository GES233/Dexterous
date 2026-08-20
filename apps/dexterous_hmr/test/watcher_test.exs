defmodule DexterousHMR.WatcherTest do
  use ExUnit.Case, async: false

  alias DexterousHMR.Watcher.Poll

  # Unique across runs: `System.unique_integer` restarts per VM, and the
  # sandbox temp survives between runs — a reused name would seed the watcher
  # with the previous run's files and mask the new writes.
  defp watch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dexterous_hmr_watch_#{System.system_time(:nanosecond)}_#{:rand.uniform(1_000_000)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "reports changed files after the debounce window" do
    dir = watch_dir()
    path = Path.join(dir, "thing.ex")
    File.write!(path, "defmodule Thing do\nend\n")

    parent = self()

    {:ok, pid} =
      Poll.start_link(
        dirs: [dir],
        interval: 20,
        debounce: 50,
        on_change: fn paths -> send(parent, {:changed, paths}) end
      )

    # The baseline scan means startup does not report.
    refute_receive {:changed, _}, 150

    File.write!(path, "defmodule Thing do\n  def x, do: 1\nend\n")
    assert_receive {:changed, paths}, 1_000
    assert path in paths

    # A later change reports again.
    File.write!(path, "defmodule Thing do\n  def x, do: 2\nend\n")
    assert_receive {:changed, _paths}, 1_000

    Poll.stop(pid)
  end

  test "a burst of changes is debounced into one batch" do
    dir = watch_dir()

    parent = self()

    {:ok, pid} =
      Poll.start_link(
        dirs: [dir],
        interval: 20,
        debounce: 120,
        on_change: fn paths -> send(parent, {:changed, paths}) end
      )

    paths =
      for i <- 1..3 do
        path = Path.join(dir, "file_#{i}.ex")
        File.write!(path, "defmodule File#{i} do\nend\n")
        Process.sleep(25)
        path
      end

    # The whole burst (~75ms of writes) lands inside the 120ms debounce
    # window, so exactly one batch is delivered.
    assert_receive {:changed, reported}, 1_000
    assert Enum.sort(reported) == Enum.sort(paths)

    # And nothing straggles in afterwards.
    refute_receive {:changed, _}, 250

    Poll.stop(pid)
  end
end
