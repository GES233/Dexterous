defmodule DexterousHMR.MixProject do
  use Mix.Project

  def project do
    [
      app: :dexterous_hmr,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # test/support/*.exs is required by test_helper, not a test file.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DexterousHMR.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dexterous, in_umbrella: true},
      {:dexterous_loader, in_umbrella: true}
    ]
  end
end
