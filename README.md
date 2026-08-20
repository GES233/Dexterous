# Dexterous

Elixir's migration for [Cordis](https://github.com/cordiverse/cordis) *(AKA. [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)'s framework)*.

An umbrella implementing *[A Programming Paradigm for Spatiotemporal
Composability](https://github.com/cordiverse/paper)* on the BEAM:

- `apps/dexterous` — **core library**: revertible effects + reactive
  coeffects + the fiber lifecycle
- `apps/dexterous_loader` — **component loader**: declarative configuration,
  reconciliation, groups
- `apps/demo` — a minimal composable app (Clock + Reporter) exercising the
  whole flow; run `mix run examples/demo.exs` from the umbrella root

## Core (`dexterous`)

- **Revertible effects** (temporal composability): `Dexterous.Context.effect/3`
  is the sole mutation primitive; every effect carries an inverse, tracked on
  the owning fiber's disposer stack and run LIFO on unload. An optional
  step-boundary `:guard` lets a fiber halt an in-flight effect sequence when its
  target changes (paper Algorithm 1).
- **Reactive coeffects** (spatial composability): components declare
  `inject/0`; bindings installed via `Context.set/3` notify dependents, whose
  fibers re-evaluate reactively. Interception metadata (e.g. a `:transform`
  function) set via `Context.intercept/3` is consulted when a key is read.
- **Fibers**: each component instantiation is a `:gen_statem` process running
  the inertial lifecycle `inactive | loading | active | unloading | failed`
  (paper Algorithm 5). Unloading a provider drains its dependents before its
  inverses run; unloading a parent cascades to its children.
- **Scopes**: the shared store is partitioned by scope; the default scope is
  the node name. `Dexterous.root(:name)` starts an independent composition
  root, so several applications can share one VM without seeing each other.
- **Process tracking**: `Dexterous.Context.track/2` registers a process the
  component started, so unloading stops it with the rest of the effects.

### Semantic Alignment and Components

- Context -> `Dexterous.Context`(immutable struct)+ shared store in ETS(`Dexterous.Store`)
- State Machine -> `:gen_statem`(`Dexterous.Fiber`)
- Component DSL -> `use Dexterous.Component, inject: [...]`

## Loader (`dexterous_loader`)

An orchestrator declares the desired composition as a list of
`DexterousLoader.Entry` records (`id / component / config / disabled /
isolate / intercept`); `DexterousLoader.reconcile/2` diffs by `id` and
applies the least disruptive operation: a config-only change is handed to the
component's optional `update/3` callback (paper Section 5.2.1), which may
absorb the payload or answer `:reload`; an isolate-only change reassigns the
entry's realms in place (paper Algorithm 7, `DexterousLoader.Isolate`),
moving the bindings the entry owns and notifying exactly the dependents the
reassignment reaches; anything else rebuilds the entry.
`DexterousLoader.Group` is an ordinary component whose config is a list of
child entries; its config changes apply as a keyed diff over child ids, so
surviving children keep their fibers. `DexterousLoader.move/3` relocates an
entry to another group (or the root) while preserving its fiber: the parent
chain is re-pointed and the realms are reassigned against the new parent via
the same Algorithm 7 machinery.

Managed realms are deterministic terms: `isolate: %{key => true}` selects a
local realm `{:local, entry_id, key}` the entry carries wherever it goes, and
`isolate: %{key => "label"}` selects a global realm `{:global, "label", key}`
shared by every entry naming it. Realm reassignment draws a fresh delimiter
tag per changed key on the entry's fiber; tags resolve down the fiber parent
chain (`Dexterous.Store.delimiter_for/3`), which is how the loader tells a
binding the entry owns (it travels) from one it merely shares (it stays).

First-cut simplifications versus the paper:

- relocating an entry by *editing group configs and reconciling* remains
  delete + recreate; identity-preserving moves go through the explicit
  `DexterousLoader.move/3` API (as does cordis's `EntryTree.update/4`)
- HMR has implemented

## Example

```elixir
defmodule Service do
  use Dexterous.Component

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
