defmodule Dexterous.Context do
  @moduledoc """
  The first-class context of the context paradigm.

  A context is an immutable struct carrying two inherited tables:

    * `:isolate` — maps a coeffect key to its realm (the store indirection)
    * `:intercept` — maps a coeffect key to interception metadata

  The value store itself lives in `Dexterous.Store` (ETS) and is shared.
  Deriving a child context (`isolate/3`, `intercept/3`) copies the struct, so
  recovery is implicit: discarding the child is enough.

  Every mutation of the shared store flows through `effect/2`, the sole
  effect primitive, which tracks an inverse per effect so that unloading
  recovers the environment in LIFO order.
  """

  alias Dexterous.Store

  defstruct fiber: nil, isolate: %{}, intercept: %{}

  @type key :: term()
  @type realm :: term()
  @type t :: %__MODULE__{
          fiber: term() | nil,
          isolate: %{key() => realm()},
          intercept: %{key() => map()}
        }

  @doc "The root context, not owned by any fiber."
  def new, do: %__MODULE__{}

  @doc "The realm a key resolves to in this context."
  def realm_for(%__MODULE__{isolate: isolate}, key), do: Map.get(isolate, key, key)

  ## Coeffect operations

  @doc """
  Read a coeffect binding: resolve the key's realm, then look the realm up in
  the store. Returns `{:ok, value}` or `:error`; never raises.
  """
  def get(%__MODULE__{} = ctx, key) do
    with {:ok, %{value: value}} <- Store.lookup(realm_for(ctx, key)) do
      {:ok, value}
    end
  end

  @doc """
  Install a coeffect binding. Provision is an effect (paper Section 3.1), so
  it goes through `effect/2`: the tracked inverse removes the binding. Both
  installation and removal notify dependents.
  """
  def set(%__MODULE__{} = ctx, key, value) do
    {:ok, _disposer} =
      effect(ctx, fn ctx ->
        realm = realm_for(ctx, key)
        Store.bind(realm, %{key: key, value: value, provider: ctx.fiber})
        notify(ctx, [key])

        fn ->
          Store.unbind(realm)
          notify(ctx, [key])
        end
      end)

    :ok
  end

  @doc """
  Derive a child context in which `key` resolves to `realm` (a freshly
  generated one by default), independent of any binding the parent sees.
  """
  def isolate(%__MODULE__{} = ctx, key, realm \\ make_ref()) do
    %{ctx | isolate: Map.put(ctx.isolate, key, realm)}
  end

  @doc """
  Derive a child context whose interception metadata for `key` is merged with
  (and takes priority over) what the context already carries.
  """
  def intercept(%__MODULE__{} = ctx, key, metadata) when is_map(metadata) do
    %{ctx | intercept: Map.update(ctx.intercept, key, metadata, &Map.merge(&1, metadata))}
  end

  @doc """
  Instantiate a component as a fiber on this context (Algorithm 4). The
  component pairs a coeffect specification `inject/0` with an effect function
  `apply/2`. Instantiation is itself a tracked effect of the parent context:
  unloading the parent cascades to the child.
  """
  def use(%__MODULE__{} = ctx, component, config) do
    id = make_ref()
    child_ctx = %{ctx | fiber: id}

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Dexterous.FiberSup,
        {Dexterous.Fiber, {id, child_ctx, ctx.fiber, component, config}}
      )

    {:ok, _disposer} =
      effect(ctx, fn _ctx ->
        GenServer.cast(pid, :refresh)

        fn ->
          Dexterous.Fiber.retire(pid)
        end
      end)

    {:ok, pid}
  end

  @doc """
  Authorized context access (Algorithm 6): walk the fiber chain upward from
  the accessing context. The first fiber whose committed view binds `key`
  authorizes the access; a fiber that declares `key` without having committed
  it raises `Dexterous.InactiveAccessError`; reaching the root without any
  declaration raises `Dexterous.UndeclaredAccessError`.
  """
  def fetch!(%__MODULE__{} = ctx, key) do
    case walk(ctx.fiber, key) do
      {:ok, value} -> value
      :inactive -> raise Dexterous.InactiveAccessError, key: key
      :undeclared -> raise Dexterous.UndeclaredAccessError, key: key
    end
  end

  defp walk(nil, _key), do: :undeclared

  defp walk(fiber_id, key) do
    case Store.get_fiber(fiber_id) do
      {:ok, fiber} ->
        cond do
          is_map(fiber.committed) and Map.has_key?(fiber.committed, key) ->
            {:ok, Map.fetch!(fiber.committed, key)}

          key in fiber.inject ->
            :inactive

          true ->
            walk(fiber.parent, key)
        end

      :error ->
        :undeclared
    end
  end

  ## Effect tracking

  @doc """
  Run `callback` as a revertible effect: the callback may return an inverse
  `-> any`, which the runtime pushes onto the owning fiber's disposer stack
  (or `:root`'s). Returns `{:ok, disposer}`; invoking the disposer recovers
  the effect, at most once, and halts it from firing again at unload time.
  """
  def effect(%__MODULE__{} = ctx, callback) when is_function(callback, 1) do
    owner = ctx.fiber || :root

    case callback.(ctx) do
      inverse when is_function(inverse, 0) ->
        disposer = once(inverse)
        Store.push_disposer(owner, disposer)
        {:ok, disposer}

      _other ->
        {:ok, fn -> :ok end}
    end
  end

  @doc """
  Propagate binding changes to dependents: any live fiber that injects one of
  `keys` and resolves it to the same realm as this context gets refreshed.
  Returns the ids of the affected fibers, so a caller can wait for them.
  """
  def notify(%__MODULE__{} = ctx, keys) do
    Store.all_fibers()
    |> Enum.filter(fn {_id, fiber} ->
      Enum.any?(keys, fn key ->
        key in fiber.inject and Map.get(fiber.isolate, key, key) == realm_for(ctx, key)
      end)
    end)
    |> Enum.map(fn {id, fiber} ->
      GenServer.cast(fiber.pid, :refresh)
      id
    end)
  end

  ## Internal

  # Wrap an inverse so it fires at most once (the `armed` flag of Algorithm 1):
  # firing twice would apply an inverse at a state no application of the
  # effect produced.
  defp once(fun) do
    armed = :atomics.new(1, [])
    :atomics.put(armed, 1, 1)

    fn ->
      if :atomics.exchange(armed, 1, 0) == 1, do: fun.(), else: :ok
    end
  end
end
