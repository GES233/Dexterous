# Demo: composable Clock + Reporter.
# Run from the umbrella root:  mix run examples/demo.exs

alias DexterousLoader.Entry

clock = fn interval -> %Entry{id: :clock, component: Demo.Clock, config: [interval: interval]} end

reporter = fn every ->
  %Entry{id: :reporter, component: Demo.Reporter, config: [every: every, target: nil]}
end

IO.puts("\n== 1. reporter alone: it waits inactive, nothing ticks ==")
{:ok, loader} = DexterousLoader.start_link(Dexterous.root(), [reporter.(1)])
Process.sleep(300)

IO.puts("\n== 2. clock appears: the reporter activates reactively ==")
:ok = DexterousLoader.reconcile(loader, [reporter.(1), clock.(200)])
Process.sleep(1000)

IO.puts("\n== 3. config change absorbed by update/3: every 3rd tick, no restart ==")
:ok = DexterousLoader.reconcile(loader, [reporter.(3), clock.(200)])
Process.sleep(1000)

IO.puts("\n== 4. clock disabled: the reporter is drained first, then the clock stops ==")
:ok = DexterousLoader.reconcile(loader, [reporter.(3), %{clock.(200) | disabled: true}])
Process.sleep(600)

IO.puts("\n== 5. a fresh clock (new provider): the reporter resubscribes ==")
:ok = DexterousLoader.reconcile(loader, [reporter.(1), clock.(100)])
Process.sleep(600)

IO.puts("\ndone.")
