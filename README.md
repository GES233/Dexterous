# Dexterous

Elixir's migration for Cordis(AKA. Framework for DeepSeek Harness).

Implements the core library of *A Programming Paradigm for Spatiotemporal
Composability* on the BEAM:

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

## Semantic Alignment and Components

- **Core**
  - Context -> `Dexterous.Context`(immutable struct)+ shared store in ETS(`Dexterous.Store`)
  - State Machine -> `:gen_statem`(`Dexterous.Fiber`)
  - Component DSL -> `use Dexterous.Component, inject: [...]`
- **Loader**(not yet)
- **HMR**(not yet)

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

ctx = Dexterous.root()
{:ok, _consumer} = Dexterous.use(ctx, Consumer, [])   # waits inactive
{:ok, _service} = Dexterous.use(ctx, Service, value: 1) # consumer activates
```
