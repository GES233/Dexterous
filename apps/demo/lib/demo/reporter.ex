defmodule Demo.Reporter do
  @moduledoc """
  Injects `:clock` and reports every `config[:every]`-th tick to
  `config[:target]` (a pid, or `nil` to log instead).

  `update/3` absorbs a new `every` without restarting the loop process.
  """

  use Dexterous.Component, inject: [:clock]

  defmodule Loop do
    @moduledoc "Inner loop."

    use GenServer
    alias Demo.Clock.Server, as: ClockServer
    require Logger

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def set_every(loop, every), do: GenServer.cast(loop, {:set_every, every})

    @impl true
    def init(opts) do
      ClockServer.subscribe(opts[:clock], self())
      {:ok, %{every: opts[:every], target: opts[:target], seen: 0}}
    end

    @impl true
    def handle_cast({:set_every, every}, state) do
      {:noreply, %{state | every: every}}
    end

    @impl true
    def handle_info({:tick, n}, state) do
      if rem(n, state.every) == 0 do
        report(state.target, n)
      end

      {:noreply, %{state | seen: state.seen + 1}}
    end

    defp report(target, n) when is_pid(target), do: send(target, {:report, n})
    defp report(_target, n), do: Logger.info("report: tick #{n}")
  end

  @impl true
  def apply(ctx, config) do
    clock = Dexterous.Context.fetch!(ctx, :clock)
    {:ok, loop} = Loop.start_link(clock: clock, every: config[:every], target: config[:target])
    Dexterous.Context.track(ctx, loop)
    # Private binding so update/3 can find our own loop process.
    Dexterous.Context.set(ctx, {:demo, :loop}, loop)
  end

  @impl true
  def update(ctx, _old, new) do
    {:ok, loop} = Dexterous.Context.get(ctx, {:demo, :loop})
    Loop.set_every(loop, new[:every])
    :ok
  end
end
