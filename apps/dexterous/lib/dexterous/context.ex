defmodule Dexterous.Context do
  @moduledoc """
  The first-class context of the context paradigm.

  A context is an immutable struct carrying:

    * `:scope` — the composition root this context belongs to (defaults to
      the node name); the shared store is partitioned by scope
    * `:isolate` — maps a coeffect key to its realm (the store indirection)
    * `:intercept` — maps a coeffect key to interception metadata
    * `:guard` — an optional `fn -> boolean()` consulted by `effect/3` at
      every step boundary (paper Algorithm 1 and Section 4.3.2)

  The value store itself lives in `Dexterous.Store` (ETS) and is shared per
  scope. Deriving a child context (`isolate/3`, `intercept/3`) copies the
  struct, so recovery is implicit: discarding the child is enough.

  Every mutation of the shared store flows through `effect/3`, the sole
  effect primitive, which tracks an inverse per effect so that unloading
  recovers the environment in LIFO order.
  """

  alias Dexterous.Store

  defstruct fiber: nil, isolate: %{}, intercept: %{}, scope: node(), guard: nil

  @type key :: term()
  @type realm :: term()
  @type scope :: term()
  @type guard :: (() -> boolean())
  @type t :: %__MODULE__{
          fiber: term() | nil,
          isolate: %{key() => realm()},
          intercept: %{key() => map()},
          scope: scope(),
          guard: guard() | nil
        }

  @doc """
  The root context, not owned by any fiber. `scope` defaults to the node
  name; pass an explicit name to run an independent composition root in the
  same VM.
  """
  def new(scope \\ node()), do: %__MODULE__{scope: scope}

  @doc "The realm a key resolves to in this context."
  def realm_for(%__MODULE__{isolate: isolate}, key), do: Map.get(isolate, key, key)

  ## Coeffect operations

  @doc """
  Read a coeffect binding: resolve the key's realm, then look the realm up in
  the store. Returns `{:ok, value}` or `:error`; never raises.

  If the accessing context carries interception metadata for this key, it is
  consulted: a `:transform` function is applied to the stored value before
  returning it.
  """
  def get(%__MODULE__{} = ctx, key) do
    with {:ok, %{value: value}} <- Store.lookup(ctx.scope, realm_for(ctx, key)) do
      {:ok, apply_intercept(value, Map.get(ctx.intercept, key))}
    end
  end

  @doc """
  Install a coeffect binding. Provision is an effect (paper Section 3.1), so
  it goes through `effect/3`: the tracked inverse removes the binding. Both
  installation and removal notify dependents.
  """
  def set(%__MODULE__{} = ctx, key, value) do
    {:ok, _disposer} =
      effect(ctx, fn ctx ->
        realm = realm_for(ctx, key)
        Store.bind(ctx.scope, realm, %{key: key, value: value, provider: ctx.fiber})
        notify(ctx, [key])

        fn ->
          # Only retract the binding if it is still ours: a replacement may
          # have rebound the realm while our unload was in flight.
          case Store.lookup(ctx.scope, realm) do
            {:ok, %{provider: provider}} when provider == ctx.fiber ->
              Store.unbind(ctx.scope, realm)
              notify(ctx, [key])

            _ ->
              :ok
          end
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

  At access time (see `fetch!/2` and `get/2`) the effective metadata for the
  key is consulted. Currently supported metadata:

    * `:transform` — an `fn value -> transformed_value` applied to the stored
      value whenever it is read through this context.
  """
  def intercept(%__MODULE__{} = ctx, key, metadata) when is_map(metadata) do
    %{ctx | intercept: Map.update(ctx.intercept, key, metadata, &Map.merge(&1, metadata))}
  end

  @doc """
  Return the effective interception metadata for `key` as seen by this
  context (already merged from ancestor contexts by `intercept/3`).
  """
  def intercept_for(%__MODULE__{intercept: intercept}, key) do
    Map.get(intercept, key, %{})
  end

  @doc """
  Authorized context access (Algorithm 6): walk the fiber chain upward from
  the accessing context. The first fiber whose committed view binds `key`
  authorizes the access; a fiber that declares `key` without having committed
  it raises `Dexterous.InactiveAccessError`; reaching the root without any
  declaration raises `Dexterous.UndeclaredAccessError`.

  Interception metadata for the key (see `intercept/3`) is applied to the
  returned value.
  """
  def fetch!(%__MODULE__{} = ctx, key) do
    case walk(ctx, ctx.fiber, key) do
      {:ok, value} -> value
      :inactive -> raise Dexterous.InactiveAccessError, key: key
      :undeclared -> raise Dexterous.UndeclaredAccessError, key: key
    end
  end

  defp walk(_ctx, nil, _key), do: :undeclared

  defp walk(%__MODULE__{} = ctx, fiber_id, key) do
    case Store.get_fiber(ctx.scope, fiber_id) do
      {:ok, fiber} ->
        cond do
          is_map(fiber.committed) and Map.has_key?(fiber.committed, key) ->
            value = Map.fetch!(fiber.committed, key)
            {:ok, apply_intercept(value, Map.get(ctx.intercept, key))}

          key in fiber.inject ->
            :inactive

          true ->
            walk(ctx, fiber.parent, key)
        end

      :error ->
        :undeclared
    end
  end

  ## Effect tracking

  @doc """
  Run `callback` as a revertible effect. The callback may return an inverse
  `-> any`, which the runtime pushes onto the owning fiber's disposer stack
  (or `:root`'s). Returns `{:ok, disposer}`; invoking the disposer recovers
  the effect, at most once, and halts it from firing again at unload time.

  Options:

    * `:guard` — an `fn -> boolean()` checked before the callback runs. If it
      returns `false`, `Dexterous.HaltedError` is raised so that the in-flight
      effect sequence can be recovered (paper Algorithm 1). When no guard is
      supplied, the context's own `:guard` field is used; otherwise the effect
      always proceeds.
  """
  def effect(%__MODULE__{} = ctx, callback, opts \\ []) when is_function(callback, 1) do
    owner = ctx.fiber || :root
    guard = Keyword.get(opts, :guard) || ctx.guard || fn -> true end

    unless guard.() do
      raise Dexterous.HaltedError, message: "effect halted by step-boundary guard"
    end

    case callback.(ctx) do
      inverse when is_function(inverse, 0) ->
        disposer = once(inverse)
        Store.push_disposer(ctx.scope, owner, disposer)
        {:ok, disposer}

      _other ->
        {:ok, fn -> :ok end}
    end
  end

  @doc """
  Track a process as an effect of this context: when the owner unloads, the
  process is stopped. Sugar over `effect/3` for the common case of a
  component starting its own processes in `apply/2`.

      def apply(ctx, _config) do
        {:ok, worker} = MyWorker.start_link([])
        Dexterous.Context.track(ctx, worker)
      end
  """
  def track(%__MODULE__{} = ctx, pid, reason \\ :normal) when is_pid(pid) do
    effect(ctx, fn _ctx ->
      fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, reason)
          catch
            :exit, _ -> :ok
          end
        end

        :ok
      end
    end)
  end

  @doc """
  Propagate binding changes to dependents: any live fiber that injects one of
  `keys` and resolves it to the same realm as this context gets refreshed.
  Returns the ids of the affected fibers, so a caller can wait for them.

  Options:

    * `:affected` — an `fn {fiber_id, fiber_attrs}, key -> boolean()`
      replacing the default realm test (paper Algorithm 7 uses this to notify
      exactly the fibers a realm reassignment reaches).
  """
  def notify(%__MODULE__{} = ctx, keys, opts \\ []) do
    affected = Keyword.get(opts, :affected)

    ctx.scope
    |> Store.all_fibers()
    |> Enum.filter(fn {id, fiber} ->
      Enum.any?(keys, fn key ->
        key in fiber.inject and
          if affected do
            affected.({id, fiber}, key)
          else
            Map.get(fiber.isolate, key, key) == realm_for(ctx, key)
          end
      end)
    end)
    |> Enum.map(fn {id, fiber} ->
      GenServer.cast(fiber.pid, :refresh)
      id
    end)
  end

  ## Component instantiation

  @doc """
  Instantiate a component as a fiber on this context (Algorithm 4). The
  component pairs a coeffect specification `inject/0` with an effect function
  `apply/2`. Instantiation is itself a tracked effect of the parent context:
  unloading the parent cascades to the child.
  """
  def use(ctx, component, config), do: use(ctx, component, config, [])

  @doc """
  Instantiate a component as a fiber, merging the `:attrs` option into the
  fiber's initial registry attributes (the loader uses this to record entry
  bookkeeping atomically with registration).
  """
  def use(%__MODULE__{} = ctx, component, config, opts) do
    id = make_ref()
    child_ctx = %{ctx | fiber: id}
    attrs = Keyword.get(opts, :attrs, %{})

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Dexterous.FiberSup,
        {Dexterous.Fiber, {id, child_ctx, ctx.fiber, component, config, attrs}}
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

  ## Internal

  # Apply interception metadata to a resolved value. Currently the only
  # supported key is `:transform`, an Elixir function.
  defp apply_intercept(value, nil), do: value

  defp apply_intercept(value, %{transform: transform} = _metadata) when is_function(transform, 1) do
    transform.(value)
  end

  defp apply_intercept(value, _metadata), do: value

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
