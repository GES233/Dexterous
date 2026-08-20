defmodule DexterousHMR.Watcher do
  @moduledoc """
  The file-watching contract.

  An implementation watches directories and delivers *debounced batches* of
  changed paths to the callback configured under `:on_change`
  (`fn [path] -> any`). `DexterousHMR.Watcher.Poll` is the mtime-polling
  implementation shipped here; a `:file_system`-backed implementation can
  replace it without touching the HMR loop, as long as it honours this
  contract.
  """

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback stop(pid()) :: :ok
end

defmodule DexterousHMR.Watcher.Poll do
  @moduledoc """
  A polling watcher (the first implementation, no extra deps).

  Options:

    * `:dirs` (required) — directories to watch recursively for `*.ex` /
      `*.exs` files
    * `:interval` — poll period in ms (default 500)
    * `:debounce` — quiet window in ms before a staged batch is delivered
      (default 100)
    * `:on_change` — `fn [path] -> any` invoked with each debounced batch

  Change detection hashes file contents, so edits within the same mtime
  granule (coarse on some filesystems) are still caught. The initial scan
  seeds the baseline, so only changes after startup are reported.
  """

  use GenServer

  @behaviour DexterousHMR.Watcher

  @impl true
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init(opts) do
    dirs = Keyword.fetch!(opts, :dirs)
    interval = Keyword.get(opts, :interval, 500)
    debounce = Keyword.get(opts, :debounce, 100)

    Process.send_after(self(), :tick, interval)

    {:ok,
     %{
       dirs: dirs,
       interval: interval,
       debounce: debounce,
       on_change: Keyword.get(opts, :on_change),
       mtimes: Map.new(scan(dirs)),
       staged: MapSet.new(),
       flushing: false
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    current = scan(state.dirs)
    changed = for {path, mtime} <- current, Map.get(state.mtimes, path) != mtime, do: path
    state = %{state | mtimes: Map.new(current)}

    if changed == [] do
      Process.send_after(self(), :tick, state.interval)
      {:noreply, state}
    else
      first_flush? = not state.flushing
      staged = Enum.reduce(changed, state.staged, fn path, acc -> MapSet.put(acc, path) end)
      state = %{state | staged: staged, flushing: true}

      if first_flush?, do: Process.send_after(self(), :flush, state.debounce)
      Process.send_after(self(), :tick, state.interval)
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    if MapSet.size(state.staged) > 0 do
      paths = MapSet.to_list(state.staged)
      if is_function(state.on_change, 1), do: state.on_change.(paths)
      {:noreply, %{state | staged: MapSet.new(), flushing: false}}
    else
      {:noreply, %{state | flushing: false}}
    end
  end

  # Recursive walk (File.ls, not Path.wildcard: filelib's wildcard is blocked
  # for some sandboxed paths).
  defp scan(dirs) do
    Enum.flat_map(dirs, &walk/1)
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &walk_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp walk_entry(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) ->
        walk(path)

      String.ends_with?(entry, ".ex") or String.ends_with?(entry, ".exs") ->
        case File.read(path) do
          {:ok, content} -> [{path, :erlang.md5(content)}]
          _ -> []
        end

      true ->
        []
    end
  end
end
