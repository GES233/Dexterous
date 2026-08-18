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

- **Revertible effects** (temporal composability): `Dexterous.Context.effect/2`
  is the sole mutation primitive; every effect carries an inverse, tracked on
  the owning fiber's disposer stack and run LIFO on unload.
- **Reactive coeffects** (spatial composability): components declare
  `inject/0`; bindings installed via `Context.set/3` notify dependents, whose
  fibers re-evaluate reactively.
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
absorb the payload or answer `:reload`; anything else rebuilds the entry.
`DexterousLoader.Group` is an ordinary component whose config is a list of
child entries, so nested trees stay within the calculus.

First-cut simplifications versus the paper:

- entries are immutable positions: moving an entry between groups is
  delete + recreate, so managed-realm reassignment (Algorithm 7) is skipped
- interception metadata is stored on contexts but not yet consulted at
  access time
- HMR is not implemented yet

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

:ok = DexterousLoader.reconcile(loader, [/* new desired entries */])
```
