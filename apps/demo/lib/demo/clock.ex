defmodule Demo.Clock do
  @moduledoc """
  Provides the `:clock` coeffect: a pid of a ticking clock server that
  subscribers receive `{:tick, n}` messages from.

  The interval is config-driven and can be changed in place through
  `update/3` — no restart, subscribers keep their subscription.
  """

  use Dexterous.Component

  defmodule Server do
    @moduledoc false

    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def subscribe(clock, pid), do: GenServer.cast(clock, {:subscribe, pid})
    def set_interval(clock, interval), do: GenServer.cast(clock, {:set_interval, interval})

    @impl true
    def init(opts) do
      schedule(opts[:interval])
      {:ok, %{interval: opts[:interval], subs: MapSet.new(), n: 0}}
    end

    @impl true
    def handle_cast({:subscribe, pid}, state) do
      {:noreply, %{state | subs: MapSet.put(state.subs, pid)}}
    end

    def handle_cast({:set_interval, interval}, state) do
      {:noreply, %{state | interval: interval}}
    end

    @impl true
    def handle_info(:tick, state) do
      for sub <- state.subs, do: send(sub, {:tick, state.n})
      schedule(state.interval)
      {:noreply, %{state | n: state.n + 1}}
    end

    defp schedule(interval), do: Process.send_after(self(), :tick, interval)
  end

  @impl true
  def apply(ctx, config) do
    {:ok, clock} = Server.start_link(interval: config[:interval])
    Dexterous.Context.track(ctx, clock)
    Dexterous.Context.set(ctx, :clock, clock)
  end

  @impl true
  def update(ctx, _old, new) do
    {:ok, clock} = Dexterous.Context.get(ctx, :clock)
    Server.set_interval(clock, new[:interval])
    :ok
  end
end
