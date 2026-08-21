defmodule Dexterous.Provider do
  @moduledoc """
  A coeffect binding that is a function of the interception metadata
  (paper Definition 30: the provider table maps each key to a provider
  `ℳₖ → 𝒱ₖ`). Installed with `Dexterous.Context.provide/3`; at read time the
  runtime applies `fun` to the metadata merged for the key — the
  component-declared `d(k)` under the context-carried `ι(k)`.
  """
  defstruct [:fun]
end

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
    * `:provide` — the provision of the fiber this context belongs to (paper
      Definition 43): the only keys `set/3` accepts from it. Empty on the
      root context, which is exempt from the check.

  The value store itself lives in `Dexterous.Store` (ETS) and is shared per
  scope. Deriving a child context (`isolate/3`, `intercept/3`) copies the
  struct, so recovery is implicit: discarding the child is enough.

  Every mutation of the shared store flows through `effect/3`, the sole
  effect primitive, which tracks an inverse per effect so that unloading
  recovers the environment in LIFO order.
  """

  alias Dexterous.Store

  defstruct fiber: nil, isolate: %{}, intercept: %{}, scope: node(), guard: nil, provide: []
  @type key :: term()
  @type realm :: term()
  @type scope :: term()
  @type guard :: (() -> boolean())
  @type t :: %__MODULE__{
          fiber: term() | nil,
          isolate: %{key() => realm()},
          intercept: %{key() => map()},
          scope: scope(),
          guard: guard() | nil,
          provide: [key()]
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

  A fiber-owned context may only set keys in its declared provision
  (`provide/0`, paper Definition 43); anything else raises
  `Dexterous.UndeclaredProvisionError`. The root context is exempt.
  """
  def set(%__MODULE__{} = ctx, key, value) do
    if ctx.fiber != nil and key not in ctx.provide do
      raise Dexterous.UndeclaredProvisionError, key: key, provide: ctx.provide
    end

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
  Install a coeffect binding whose value is computed from the interception
  metadata at read time (paper Definition 31, `get = ρ(k)(d(k) ⊕ₖ ι(k))`):
  `fun` receives the merged metadata map — component-declared under
  context-carried — and returns the value the reader sees. This is the basis
  of metadata-mediated access control (paper Section 6.3).

  Like `set/3`, provision is a tracked effect subject to the component's
  declared provision.
  """
  def provide(%__MODULE__{} = ctx, key, fun) when is_function(fun, 1) do
    set(ctx, key, %Dexterous.Provider{fun: fun})
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

  Any other fields are passed through to a provider function (see
  `provide/3`). The merge follows the key's metadata monoid (paper
  Definition 30): scalar fields are overwritten by the newer layer,
  `MapSet`-valued fields are unioned.
  """
  def intercept(%__MODULE__{} = ctx, key, metadata) when is_map(metadata) do
    %{ctx | intercept: Map.update(ctx.intercept, key, metadata, &merge_metadata(&1, metadata))}
  end

  @doc """
  The metadata monoid merge (paper Definition 30, `⊕ₖ`): right-biased, so
  the second map's scalar fields win, while `MapSet`-valued fields are
  unioned. Used for every layer of interception metadata — context-carried
  over component-declared, child over parent.
  """
  def merge_metadata(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay, fn
      _field, %MapSet{} = a, %MapSet{} = b -> MapSet.union(a, b)
      _field, _a, b -> b
    end)
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

  The callback may also iterate (paper Definitions 51–52, the effect
  iterator): returning `{inverse, continuation}` records `inverse`, checks
  the guard at the step boundary, and invokes the zero-arity `continuation`
  for the next step, which yields the same shape again. Iteration ends with a
  bare inverse or any other value. Each step's inverse is pushed separately,
  so recovery unwinds the whole iteration in LIFO order.

  Options:

    * `:guard` — an `fn -> boolean()` checked before the callback runs and at
      every iteration boundary. If it returns `false`,
      `Dexterous.HaltedError` is raised so that the in-flight effect sequence
      can be recovered (paper Algorithm 1). When no guard is supplied, the
      context's own `:guard` field is used; otherwise the effect always
      proceeds.
  """
  def effect(%__MODULE__{} = ctx, callback, opts \\ []) when is_function(callback, 1) do
    owner = ctx.fiber || :root
    guard = Keyword.get(opts, :guard) || ctx.guard || fn -> true end

    check_guard!(guard)
    iterate(ctx, owner, guard, callback.(ctx))
  end

  # One iteration step (paper Definition 51): a triple of new context
  # (implicit here — contexts are immutable values the callback closes over),
  # the step's inverse, and the continuation signal.
  defp iterate(ctx, owner, guard, {inverse, continuation})
       when is_function(inverse, 0) and is_function(continuation, 0) do
    push_inverse(ctx, owner, inverse)
    check_guard!(guard)
    iterate(ctx, owner, guard, continuation.())
  end

  defp iterate(ctx, owner, _guard, inverse) when is_function(inverse, 0) do
    {:ok, push_inverse(ctx, owner, inverse)}
  end

  defp iterate(_ctx, _owner, _guard, _other) do
    {:ok, fn -> :ok end}
  end

  defp push_inverse(ctx, owner, inverse) do
    disposer = once(inverse)
    Store.push_disposer(ctx.scope, owner, disposer)
    disposer
  end

  defp check_guard!(guard) do
    unless guard.() do
      raise Dexterous.HaltedError, message: "effect halted by step-boundary guard"
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
  Write back to the entry record of the fiber owning this context (paper
  Section 5.2.1: the entry/fiber binding runs in both directions). `fun`
  receives the entry record and returns the revised one — e.g. a component
  that revises its own configuration:

      Context.write_back(ctx, fn entry -> %{entry | config: new_config} end)

  The loader adopts the revised record on its next reconcile, and an in-place
  reload (`DexterousLoader.reload_entry/2`) respawns from it. To disable
  itself, a component writes `disabled: true` back and calls
  `retire_self/1`. Returns `:ok`, or `:error` for the root context or a
  fiber without an entry record.
  """
  def write_back(%__MODULE__{fiber: nil}, _fun), do: :error

  def write_back(%__MODULE__{} = ctx, fun) when is_function(fun, 1) do
    Store.update_entry(ctx.scope, ctx.fiber, fun)
  end

  @doc """
  Ask the fiber owning this context to unload and retire. Typically paired
  with a `write_back/2` that records *why* (e.g. `disabled: true`).
  """
  def retire_self(%__MODULE__{fiber: nil}), do: :error

  def retire_self(%__MODULE__{} = ctx) do
    case Store.get_fiber(ctx.scope, ctx.fiber) do
      {:ok, %{pid: pid}} -> Dexterous.Fiber.retire(pid)
      :error -> :error
    end
  end

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

    # The component-declared interception metadata d(k) forms the base layer;
    # the context-carried ι(k) the fiber inherits takes priority over it
    # (paper Definition 31, right-biased ⊕ₖ).
    declared = Dexterous.Component.inject_meta_of(component)

    intercept =
      Enum.reduce(declared, ctx.intercept, fn {key, metadata}, acc ->
        Map.update(acc, key, metadata, &merge_metadata(metadata, &1))
      end)

    child_ctx = %{
      ctx
      | fiber: id,
        provide: Dexterous.Component.provide_of(component),
        intercept: intercept
    }
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

  # Apply interception metadata to a resolved value. A Provider binding is a
  # function of the merged metadata (paper Definition 31); for plain values
  # the only supported metadata key is `:transform`, an Elixir function.
  defp apply_intercept(%Dexterous.Provider{fun: provider}, metadata) do
    provider.(metadata || %{})
  end

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
