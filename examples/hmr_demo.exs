# Demo: hot module replacement with DexterousHMR.
#
# Run from the umbrella root:  mix run examples/hmr_demo.exs
#
# The script writes a tiny component module (a "clock" that reports its
# version) into a temp directory, loads it, starts a loader + the HMR loop,
# then *rewrites the source file* — exactly what an editor save does. The
# watcher notices the change, an HMR cycle recompiles and reloads the module,
# and the stale entry is swapped to the new version, transactionally, without
# restarting anything.

defmodule HmrDemo.Reporter do
  @moduledoc false
  def start, do: spawn(fn -> loop() end)

  defp loop do
    receive do
      {:hmr_demo, kind, version} ->
        IO.puts("  clock #{kind} v#{version}")
        loop()
    end
  end
end

version_source = fn version ->
  """
  defmodule HmrDemo.Clock do
    use Dexterous.Component

    @impl true
    def apply(ctx, config) do
      send(config[:reporter], {:hmr_demo, :applied, #{version}})

      Dexterous.Context.effect(ctx, fn _ ->
        fn -> send(config[:reporter], {:hmr_demo, :disposed, #{version}}) end
      end)
    end
  end
  """
end

tmp = Path.join(System.tmp_dir!(), "dexterous_hmr_demo")
ebin = Path.join(tmp, "ebin")
source = Path.join(tmp, "clock.ex")
File.mkdir_p!(ebin)
File.write!(source, version_source.(1))

# The demo redefines the already-loaded HmrDemo.Clock on every cycle; silence
# the "redefining module" warning and use the structured-diagnostics API.
Code.put_compiler_option(:ignore_module_conflict, true)

alias DexterousLoader.Entry

IO.puts("== loading clock.ex v1 and starting the composition ==")

{:ok, [mod], _} = Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)
beam = Path.join(ebin, "Elixir.HmrDemo.Clock.beam")
:code.load_binary(mod, String.to_charlist(beam), File.read!(beam))

reporter = HmrDemo.Reporter.start()

# Recompiles whatever clock.ex currently contains and loads it — the role Mix
# compile plays in dev. The watcher never sees this as a source change (the
# compiler only writes the .beam), so cycles do not self-trigger.
compile_and_load = fn ->
  {:ok, [^mod], _} = Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)
  :code.load_binary(mod, String.to_charlist(beam), File.read!(beam))
  mod
end

{:ok, loader} =
  DexterousLoader.start_link(Dexterous.root(), [
    %Entry{id: :clock, component: mod, config: [reporter: reporter]}
  ])

Process.sleep(300)

IO.puts("\n== starting the HMR loop with its file watcher (no manual wiring) ==")

{:ok, _} =
  DexterousHMR.start_link(
    watcher: [dirs: [tmp], interval: 300, debounce: 150],
    watch_dirs: [tmp],
    compile_fun: compile_and_load,
    settle_timeout: 2_000
  )

:ok = DexterousHMR.register(loader, [])

IO.puts("\n== simulating an editor save: rewriting clock.ex as v2 ==")
File.write!(source, version_source.(2))

IO.puts("\n== waiting for the watcher to notice and swap the entry ==")
Process.sleep(2_000)

IO.puts("\n== the fiber now runs v2; the old v1 code was purged ==")
IO.puts("done.")
