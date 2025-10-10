defmodule ReqLLM.MixProject do
  use Mix.Project

  @version "1.0.0-rc.5"
  @source_url "https://github.com/agentjido/req_llm"

  def project do
    [
      app: :req_llm,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Test coverage
      test_coverage: [tool: ExCoveralls, export: "cov", exclude: [:coverage]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        "req_llm.model_compat": :test,
        mc: :test
      ],

      # Dialyzer configuration
      dialyzer: [
        plt_add_apps: [:mix]
      ],

      # Package
      package: package(),

      # Documentation
      name: "ReqLLM",
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: "v#{@version}",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/getting-started.md",
          "guides/core-concepts.md",
          "guides/api-reference.md",
          "guides/data-structures.md",
          "guides/model-metadata.md",
          "guides/coverage-testing.md",
          "guides/adding_a_provider.md"
        ],
        groups_for_extras: [
          Guides: ~r/guides\/.*/
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ReqLLM.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jido_keys, "~> 1.0"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:server_sent_events, "~> 0.2"},
      {:splode, "~> 0.2.3"},
      {:typed_struct, "~> 0.3.0"},
      {:uniq, "~> 0.6"},

      # Dev/test dependencies
      {:bandit, "~> 1.8", only: :dev, runtime: false},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.11", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      description: "Composable Elixir library for LLM interactions built on Req & Finch",
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{"GitHub" => @source_url, "Agent Jido" => "https://agentjido.xyz"},
      files: ~w(lib priv mix.exs LICENSE README.md AGENTS.md usage-rules.md guides .formatter.exs)
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "dialyzer",
        "credo --strict"
      ],
      q: ["quality"],
      mc: ["req_llm.model_compat"]
    ]
  end
end
