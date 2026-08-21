# Dexterous

Elixir's migration for [Cordis](https://github.com/cordiverse/cordis) *(AKA. [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)'s framework)*.

An umbrella implementing *[A Programming Paradigm for Spatiotemporal
Composability](https://github.com/cordiverse/paper)* on the BEAM:

- `apps/dexterous` — **core library**: revertible effects + reactive
  coeffects + the fiber lifecycle
- `apps/dexterous_loader` — **component loader**: declarative configuration,
  reconciliation, groups, includes, static validation
- `apps/dexterous_hmr` — **hot module replacement** (dev-only): file
  watching, transactional reload with rollback
- `apps/demo` — a minimal composable app (Clock + Reporter) exercising the
  whole flow; run `mix run examples/demo.exs` from the umbrella root

## Core (`dexterous`)

- **Revertible effects** (temporal composability): `Dexterous.Context.effect/3`
  is the sole mutation primitive; every effect carries an inverse, tracked on
  the owning fiber's disposer stack and run LIFO on unload. An optional
  step-boundary `:guard` lets a fiber halt an in-flight effect sequence when its
  target changes (paper Algorithm 1). `effect/3` also accepts the effect
  iterator of paper Definitions 51–52 — return `{inverse, continuation}` to
  run a multi-step effect with a guard check at every step boundary.
- **Reactive coeffects** (spatial composability): components declare
  `inject/0` (with optional per-key metadata, paper Definition 30) and their
  provision `provide/0` (paper Definition 43); bindings installed via
  `Context.set/3` notify dependents, whose fibers re-evaluate reactively.
  A fiber may only `set/3` keys in its declared provision
  (`Dexterous.UndeclaredProvisionError` otherwise).
- **Interception**: metadata attaches to dependency access per key, with a
  monoidal merge (right-biased, `MapSet` fields union — `⊕ₖ`).
  Component-declared `d(k)` merges under context-carried `ι(k)` set via
  `Context.intercept/3`. A binding installed with `Context.provide/3` is a
  function of the merged metadata (`ℳₖ → 𝒱ₖ`), which is how metadata-mediated
  access control (paper Section 6.3) is expressed; a plain `:transform`
  function is applied to plain bindings at read time.
- **Fibers**: each component instantiation is a `:gen_statem` process running
  the inertial lifecycle `inactive | loading | active | unloading | failed`
  (paper Algorithm 5). Unloading a provider drains its dependents before its
  inverses run; unloading a parent cascades to its children.
- **Scopes**: the shared store is partitioned by scope; the default scope is
  the node name. `Dexterous.root(:name)` starts an independent composition
  root, so several applications can share one VM without seeing each other.
- **Process tracking**: `Dexterous.Context.track/2` registers a process the
  component started, so unloading stops it with the rest of the effects.
- **Write-back**: `Context.write_back/2` lets a component revise its own
  entry record (and `Context.retire_self/1` retire itself) — the
  component-to-loader direction of the entry/fiber binding (paper
  Section 5.2.1).

### Semantic Alignment and Components

- Context -> `Dexterous.Context`(immutable struct)+ shared store in ETS(`Dexterous.Store`)
- State Machine -> `:gen_statem`(`Dexterous.Fiber`)
- Component DSL -> `use Dexterous.Component, inject: [...], provide: [...]`

## Loader (`dexterous_loader`)

An orchestrator declares the desired composition as a list of
`DexterousLoader.Entry` records (`id / component / config / disabled /
isolate / intercept`); `DexterousLoader.reconcile/2` diffs by `id` and
applies the least disruptive operation (paper Section 5.2.1):

- an **intercept-only** change updates the fiber's metadata in place — it is
  consulted at read time, so no reload happens;
- a **config-only** change is handed to the component's optional `update/3`
  callback, which may absorb the payload or answer `:reload`; a config change
  aimed at a non-active fiber rebuilds it instead (a reconfigure cast would
  be silently dropped — paper Section 4.3.4 leaves recovery to the
  orchestrator);
- an **isolate** change reassigns the entry's realms in place (paper
  Algorithm 7, `DexterousLoader.Isolate`), moving the bindings the entry owns
  and notifying exactly the dependents the reassignment reaches;
- an id that **vanished from one parent and appeared under another** is a
  relocation: the fiber is moved (`DexterousLoader.move/3` machinery) instead
  of deleted and recreated;
- anything else rebuilds the entry (retire + re-instantiate).

`DexterousLoader.Group` is an ordinary component whose config is a list of
child entries; its config changes apply as a keyed diff over child ids, so
surviving children keep their fibers. `DexterousLoader.Include` grafts a
subtree from an external JSON configuration file; `write_entries/2` /
`load_entries/1` persist and read back such files (the authoritative record
of paper Section 5.2.1). `DexterousLoader.move/3` relocates an entry
explicitly while preserving its fiber.

`DexterousLoader.validate/1` statically checks the declarations (paper
Section 6.5): dependency cycles and duplicate provisions of one key in one
realm are reported at load/reconcile time (via `Logger`) instead of leaving
fibers permanently inactive.

Managed realms are deterministic terms: `isolate: %{key => true}` selects a
local realm `{:local, entry_id, key}` the entry carries wherever it goes, and
`isolate: %{key => "label"}` selects a global realm `{:global, "label", key}`
shared by every entry naming it. Realm reassignment draws a fresh delimiter
tag per changed key on the entry's fiber; tags resolve down the fiber parent
chain (`Dexterous.Store.delimiter_for/3`), which is how the loader tells a
binding the entry owns (it travels) from one it merely shares (it stays).

## HMR (`dexterous_hmr`, dev-only)

`DexterousHMR` watches source dirs, recompiles, diffs loaded modules by md5,
and transactionally retires/respawns the stale entries of every registered
loader, with backup + rollback on the code server's two-version scheme.
Start it with `:watcher` (or `config :dexterous_hmr, :watcher`) and the
file-change → recompile → reload loop runs without any host wiring;
`DexterousHMR.trigger_compile/1` remains available for manual triggers.
Known limitations (externals cannot be kept unloaded, dev-only, no protocol
consolidation, no cross-node distribution) are documented in the module docs.

## Example

```elixir
defmodule Service do
  use Dexterous.Component, provide: [:service]

  @impl true
  def apply(ctx, config) do
    Dexterous.Context.set(ctx, :service, config[:value])
  end
end

defmodule Consumer do
  use Dexterous.Component, inject: [:service]

  @impl true
  def apply(ctx, _config) do
    value = Dexterous.Context.fetch!(ctx, :service)
    # ...
  end
end

{:ok, loader} =
  DexterousLoader.start_link(Dexterous.root(), [
    %DexterousLoader.Entry{id: :svc, component: Service, config: [value: 1]},
    %DexterousLoader.Entry{id: :use, component: Consumer, config: []}
  ])

:ok = DexterousLoader.reconcile(loader, [" ...new desired entries "])
```
