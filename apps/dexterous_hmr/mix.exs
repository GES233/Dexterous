defmodule DexterousHMR.MixProject do
  use Mix.Project

  # True when this app is compiled as a child of the Dexterous umbrella
  # (the parent mix.exs declares `apps_path`); false when it is consumed
  # standalone — as a hex package, a git sparse checkout, or a vendored
  # subdirectory — in which case sibling apps resolve as hex deps instead.
  @in_umbrella (case File.read(Path.expand("../../mix.exs", __DIR__)) do
                  {:ok, content} -> String.contains?(content, "apps_path")
                  _ -> false
                end)

  def project do
    [
      app: :dexterous_hmr,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description:
        "Dev-only hot module replacement for Dexterous compositions: " <>
          "file watching, transactional reload and rollback.",
      package: package(),
      # test/support/*.exs is required by test_helper, not a test file.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ] ++ umbrella_paths()
  end

  # Shared build/config/deps paths with the umbrella root. Dropped when the
  # app is compiled standalone, so relative paths never escape the dep dir.
  defp umbrella_paths do
    if @in_umbrella do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DexterousHMR.Application, []}
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs),
      links: %{"GitHub" => "https://github.com/GES233/Dexterous"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    if @in_umbrella do
      [
        {:dexterous, in_umbrella: true},
        {:dexterous_loader, in_umbrella: true}
      ]
    else
      [
        {:dexterous, "~> 0.1"},
        {:dexterous_loader, "~> 0.1"}
      ]
    end
  end
end
