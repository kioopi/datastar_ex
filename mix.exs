defmodule DatastarEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kioopi/datastar_ex"

  def project do
    [
      app: :datastar_ex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit, :stream_data, :plug, :mix]],
      aliases: aliases(),
      name: "DatastarEx",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "An ADR-compliant Datastar SDK for Elixir: server-sent event generation, " <>
      "signal reading and an optional Plug integration."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Datastar" => "https://data-star.dev/",
        "SDK ADR" => "https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE docs/conformance.md guides)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/client_attributes.md",
        "CHANGELOG.md",
        "docs/conformance.md",
        "docs/benchmarks.md"
      ],
      groups_for_extras: [Guides: ~r"guides/"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.0", only: :test},
      {:server_sent_events, "~> 1.1", only: :test, runtime: false},
      {:stream_data, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false, warn_if_outdated: true}
    ]
  end

  defp aliases() do
    [
      # Fast gate, run after every change (~10s warm). Everything here needs
      # no toolchain beyond Elixir.
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells",
        "sobelow --no-router --quiet"
      ],
      # Full gate, run in CI and before a release. Adds the checks that need
      # Go (official conformance suite), Chrome (browser smoke tests) and the
      # network (retired-dependency audit), plus the package boundary.
      #
      # `hex.audit` runs first on purpose: `dialyzer` and `reach.check`
      # leave the Hex archive off the code path, and a later `hex.audit`
      # fails with "the task could not be found".
      ci: [
        "hex.audit",
        "precommit",
        "cmd ./scripts/test/plugless",
        "cmd ./scripts/conformance",
        "cmd ./scripts/test/browser"
      ]
    ]
  end
end
