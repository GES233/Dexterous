defmodule Dexterous.Fiber do
  @moduledoc """
  A fiber: the instantiation of a component, realized as the inertial
  lifecycle state machine of paper Section 4.3.3 (Algorithm 5).

  States: `:inactive | :loading | :active | :unloading | :failed`.

  Inertia: once a reload or unload transition begins, it runs to completion
  before the fiber responds to a new target; target changes that arrive
  mid-transition are recorded on `data.target` and acted on at the transition
  boundary. `data.target` is `:unsatisfied` or a map `%{key => provider_id}`
  — identifying a binding by its provider (a fresh, never-reused id) rather
  than by its value is what makes a single comparison sufficient.

  Step-boundary guard: before each effect applied during `reload`, the
  in-flight target is compared against the target captured at the start of
  the transition. If they differ, `Dexterous.HaltedError` is raised so that
  only the already-applied effects are recovered (paper Algorithm 1).
  """

  @behaviour :gen_statem

  alias Dexterous.{Context, Store}

  defstruct [
    :id,
    :ctx,
    :component,
    :config,
    :inject,
    :apply_pid,
    :apply_mon,
    :update_pid,
    :update_mon,
    target: :unsatisfied,
    target0: nil,
    committed: nil,
    pending: nil,
    waiters: [],
    retiring: false,
    last_error: nil
  ]

  ## Public API

  def start_link({id, %Context{} = ctx, parent, component, config}) do
    :gen_statem.start_link(__MODULE__, {id, ctx, parent, component, config}, [])
  end

  def child_spec({id, ctx, parent, component, config}) do
    %{
      id: {:dexterous_fiber, id},
      start: {__MODULE__, :start_link, [{id, ctx, parent, component, config}]},
      restart: :temporary
    }
  end

  @doc "Ask the fiber to unload and retire: unload, then exit and drop from the runtime."
  def retire(pid), do: GenServer.cast(pid, :retire)

  @doc """
  Hand a new config to the fiber (paper Section 5.2.1): if the component
  exports `update/3`, it decides how to apply the new payload (`:ok` keeps
  the fiber running, `:reload` rebuilds it in place); otherwise the fiber is
  rebuilt via unload + reload.
  """
  def reconfigure(pid, config), do: GenServer.cast(pid, {:reconfigure, config})

  @doc "Introspection: `%{id:, state:, target:, committed:, last_error:}`."
  def status(pid), do: :gen_statem.call(pid, :status)

  ## gen_statem callbacks

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({id, ctx, parent, component, config}) do
    inject = component.inject()

    Store.register_fiber(ctx.scope, id, %{
      pid: self(),
      parent: parent,
      inject: inject,
      isolate: ctx.isolate,
      state: :inactive,
      target: :unsatisfied,
      committed: nil
    })

    {:ok, :inactive,
     %__MODULE__{
       id: id,
       ctx: ctx,
       component: component,
       config: config,
       inject: inject,
       pending: MapSet.new()
     }}
  end

  @impl true
  def handle_event({:call, from}, :status, state, data) do
    {:keep_state_and_data,
     [
       {:reply, from,
        %{
          id: data.id,
          state: state,
          target: data.target,
          committed: data.committed,
          last_error: data.last_error
        }}
     ]}
  end

  def handle_event(:cast, :refresh, state, data) do
    new_target = resolve_target(data.ctx.scope, data.inject, data.ctx.isolate)

    cond do
      data.retiring ->
        :keep_state_and_data

      state == :failed ->
        :keep_state_and_data

      new_target == data.target ->
        # Idempotent: a neutral change is harmless.
        :keep_state_and_data

      state in [:loading, :unloading] or data.update_pid != nil ->
        # Inertia: record the new target, let the transition complete.
        Store.update_fiber(data.ctx.scope, data.id, %{target: new_target})
        {:keep_state, %{data | target: new_target}}

      new_target == :unsatisfied ->
        start_unload(%{data | target: new_target})

      true ->
        start_reload(%{data | target: new_target})
    end
  end

  def handle_event(:cast, :retire, state, data) do
    data = %{data | retiring: true, target: :unsatisfied}
    Store.update_fiber(data.ctx.scope, data.id, %{target: :unsatisfied})

    case state do
      :inactive -> stop_fiber(data)
      :failed -> stop_fiber(data)
      :active -> if_busy(data, &start_unload/1)
      :loading -> {:keep_state, data}
      :unloading -> {:keep_state, data}
    end
  end

  def handle_event(:cast, {:reconfigure, new_config}, :active, %{update_pid: nil} = data) do
    if updatable?(data.component) do
      start_update(data, new_config)
    else
      # No update/3: rebuild in place. The target digest is unchanged, so
      # finish_unload chains straight into reload with the new config.
      start_unload(%{data | config: new_config})
    end
  end

  def handle_event(:cast, {:reconfigure, _new_config}, _state, _data) do
    # Only an active, settled fiber takes a new config; a loader should
    # rebuild fibers in any other state.
    :keep_state_and_data
  end

  def handle_event(:cast, {:notify_inactive, waiter, waiter_id}, state, data) do
    cond do
      state in [:inactive, :failed] ->
        send(waiter, {:fiber_inactive, data.id})
        :keep_state_and_data

      state == :unloading and MapSet.member?(data.pending, waiter_id) ->
        # Mutual dependency: the waiter is itself waiting on us. Break the
        # cycle by letting it proceed; our real arrival still reaches it later.
        send(waiter, {:fiber_inactive, data.id})
        :keep_state_and_data

      true ->
        {:keep_state, %{data | waiters: [waiter | data.waiters]}}
    end
  end

  def handle_event(:info, {:apply_done, pid, result}, :loading, %{apply_pid: pid} = data) do
    Process.demonitor(data.apply_mon, [:flush])
    data = %{data | apply_pid: nil, apply_mon: nil}

    case result do
      :ok ->
        if data.target == data.target0 do
          Store.update_fiber(data.ctx.scope, data.id, %{state: :active})
          Context.notify(data.ctx, Store.keys_provided_by(data.ctx.scope, data.id))
          {:next_state, :active, data}
        else
          # The target moved while apply ran: chain into unload.
          start_unload(data)
        end

      {:error, {%Dexterous.HaltedError{}, _}} ->
        # Step-boundary guard fired: recover what we already applied and then
        # continue with unload (the target has changed).
        recover(data)
        Store.update_fiber(data.ctx.scope, data.id, %{committed: nil})
        start_unload(%{data | committed: nil})

      {:error, reason} ->
        recover(data)
        Store.update_fiber(data.ctx.scope, data.id, %{state: :failed, committed: nil})
        data = %{data | target: :unsatisfied, last_error: reason, waiters: notify_waiters(data)}
        {:next_state, :failed, data}
    end
  end

  def handle_event(
        :info,
        {:update_done, pid, result, new_config},
        :active,
        %{
          update_pid: pid
        } = data
      ) do
    Process.demonitor(data.update_mon, [:flush])
    data = %{data | update_pid: nil, update_mon: nil}

    case result do
      :ok ->
        data = %{data | config: new_config}

        if data.retiring do
          start_unload(data)
        else
          # The component absorbed the new payload; re-evaluate the target in
          # case it moved while the update ran.
          GenServer.cast(self(), :refresh)
          {:keep_state, data}
        end

      :reload ->
        start_unload(%{data | config: new_config})

      {:error, reason} ->
        recover(data)
        Store.update_fiber(data.ctx.scope, data.id, %{state: :failed, committed: nil})
        data = %{data | target: :unsatisfied, last_error: reason, waiters: notify_waiters(data)}
        if data.retiring, do: stop_fiber(data), else: {:next_state, :failed, data}
    end
  end

  def handle_event(
        :info,
        {:DOWN, mon, :process, pid, reason},
        :loading,
        %{
          apply_pid: pid,
          apply_mon: mon
        } = data
      ) do
    handle_event(:info, {:apply_done, pid, {:error, reason}}, :loading, data)
  end

  def handle_event(
        :info,
        {:DOWN, mon, :process, pid, reason},
        :active,
        %{
          update_pid: pid,
          update_mon: mon
        } = data
      ) do
    Process.demonitor(mon, [:flush])
    data = %{data | update_pid: nil, update_mon: nil}
    recover(data)
    Store.update_fiber(data.ctx.scope, data.id, %{state: :failed, committed: nil})
    data = %{data | target: :unsatisfied, last_error: reason, waiters: notify_waiters(data)}
    {:next_state, :failed, data}
  end

  def handle_event(:info, {:fiber_inactive, dependent}, :unloading, data) do
    data = %{data | pending: MapSet.delete(data.pending, dependent)}

    if MapSet.size(data.pending) == 0 do
      finish_unload(data)
    else
      {:keep_state, data}
    end
  end

  def handle_event(_kind, _event, _state, _data) do
    :keep_state_and_data
  end

  ## Transitions

  # reload: commit the resolved view, run the component's effect function in a
  # separate process (the state machine stays responsive, which is what makes
  # transitions inertial), then check the target at completion.
  defp start_reload(data) do
    target0 = data.target
    scope = data.ctx.scope
    committed = resolve_view(scope, data.inject, data.ctx.isolate)
    Store.update_fiber(scope, data.id, %{state: :loading, committed: committed, target: target0})

    statem = self()
    %{component: component, ctx: ctx, config: config} = data

    # Step-boundary guard: each effect consults whether the desired target
    # is still the one this reload was started for.
    guard = fn ->
      case Store.get_fiber(scope, ctx.fiber) do
        {:ok, %{target: ^target0}} -> true
        _ -> false
      end
    end

    apply_ctx = %{ctx | guard: guard}

    {pid, mon} =
      spawn_monitor(fn ->
        result =
          try do
            _ = component.apply(apply_ctx, config)
            :ok
          rescue
            exception -> {:error, {exception, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(statem, {:apply_done, self(), result})
      end)

    {:next_state, :loading,
     %{data | target0: target0, committed: committed, apply_pid: pid, apply_mon: mon}}
  end

  # update: hand the new config to the component itself (paper Section 5.2.1),
  # in a separate process so the state machine stays responsive.
  defp start_update(data, new_config) do
    statem = self()
    %{component: component, ctx: ctx, config: old_config} = data

    {pid, mon} =
      spawn_monitor(fn ->
        result =
          try do
            case component.update(ctx, old_config, new_config) do
              :reload -> :reload
              _ -> :ok
            end
          rescue
            exception -> {:error, {exception, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(statem, {:update_done, self(), result, new_config})
      end)

    {:keep_state, %{data | update_pid: pid, update_mon: mon}}
  end

  # unload: the fiber stops providing *before* any inverse is scheduled, its
  # dependents are notified and drained, and only then are the tracked
  # inverses are run in LIFO order.
  defp start_unload(data) do
    scope = data.ctx.scope
    Store.update_fiber(scope, data.id, %{state: :unloading})
    affected = Context.notify(data.ctx, Store.keys_provided_by(scope, data.id))

    pending =
      MapSet.new(affected, fn dep ->
        case Store.get_fiber(scope, dep) do
          {:ok, %{pid: pid}} -> GenServer.cast(pid, {:notify_inactive, self(), data.id})
          :error -> :ok
        end

        dep
      end)

    data = %{data | pending: pending}

    if MapSet.size(pending) == 0 do
      finish_unload(data)
    else
      {:next_state, :unloading, data}
    end
  end

  defp finish_unload(data) do
    recover(data)
    Store.update_fiber(data.ctx.scope, data.id, %{state: :inactive, committed: nil})
    data = %{data | committed: nil, waiters: notify_waiters(data)}

    cond do
      data.retiring -> stop_fiber(data)
      data.target != :unsatisfied -> start_reload(data)
      true -> {:next_state, :inactive, data}
    end
  end

  defp stop_fiber(data) do
    Store.delete_fiber(data.ctx.scope, data.id)
    {:stop, :normal, data}
  end

  ## Helpers

  defp if_busy(data, fun) do
    if data.update_pid != nil, do: {:keep_state, data}, else: fun.(data)
  end

  defp updatable?(component) do
    Code.ensure_loaded?(component) and function_exported?(component, :update, 3)
  end

  # Run the fiber's tracked inverses in LIFO order (the accumulator).
  defp recover(data) do
    data.ctx.scope
    |> Store.take_disposers(data.id)
    |> Enum.each(fn disposer ->
      try do
        disposer.()
      rescue
        _ -> :ok
      end
    end)
  end

  defp notify_waiters(data) do
    Enum.each(data.waiters, &send(&1, {:fiber_inactive, data.id}))
    []
  end

  # The target view: for every injected key, the fiber currently providing it,
  # or :unsatisfied. A binding counts as provided only while its provider is
  # :active; bindings installed from the root context are always available.
  defp resolve_target(scope, inject, isolate) do
    Enum.reduce_while(inject, {:ok, %{}}, fn key, {:ok, acc} ->
      realm = Map.get(isolate, key, key)

      case Store.lookup(scope, realm) do
        {:ok, %{provider: nil}} ->
          {:cont, {:ok, Map.put(acc, key, :root)}}

        {:ok, %{provider: provider}} ->
          case Store.get_fiber(scope, provider) do
            {:ok, %{state: :active}} -> {:cont, {:ok, Map.put(acc, key, provider)}}
            _ -> {:halt, :unsatisfied}
          end

        :error ->
          {:halt, :unsatisfied}
      end
    end)
    |> case do
      {:ok, target} -> target
      :unsatisfied -> :unsatisfied
    end
  end

  defp resolve_view(scope, inject, isolate) do
    Map.new(inject, fn key ->
      {:ok, %{value: value}} = Store.lookup(scope, Map.get(isolate, key, key))
      {key, value}
    end)
  end
end
