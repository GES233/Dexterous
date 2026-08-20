defmodule DexterousHMR.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The HMR loop is started lazily by the host (DexterousHMR.start_link/1);
      # the application itself owns nothing so tests can run without a VM-wide
      # watcher.
    ]

    opts = [strategy: :one_for_one, name: DexterousHMR.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
