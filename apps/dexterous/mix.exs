defmodule Dexterous.MixProject do
  use Mix.Project

  def project do
    [
      app: :dexterous,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description:
        "Revertible effects and reactive coeffects on the BEAM: " <>
          "the context/fiber paradigm for spatiotemporal composability.",
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Dexterous.Application, []}
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
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
