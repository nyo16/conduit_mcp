defmodule ConduitMcp.MixProject do
  use Mix.Project

  @version "0.8.5"
  @source_url "https://github.com/nyo16/conduit_mcp"

  def project do
    [
      app: :conduit_mcp,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      docs: docs(),
      name: "ConduitMCP",
      source_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {ConduitMcp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core dependencies
      {:plug, "~> 1.19"},
      {:bandit, "~> 1.9"},
      {:nimble_options, "1.1.1"},

      # Optional: Rate limiting (only needed if using ConduitMcp.Plugs.RateLimit)
      {:hammer, "~> 7.2", optional: true},

      # Optional: Prometheus metrics via PromEx
      {:prom_ex, "~> 1.11", optional: true},

      # Optional: OAuth 2.1 JWT validation (only needed if using :oauth auth strategy)
      {:joken, "~> 2.6", optional: true},
      {:jose, "~> 1.11", optional: true},

      # Optional: HTTP client for JWKS key fetching (only needed for JWKS key provider)
      {:req, "~> 0.5", optional: true},

      # Development
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},

      # Benchmarking
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:benchee_html, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir implementation of the Model Context Protocol (MCP) specification.
    Build MCP servers to expose tools, resources, and prompts to LLM applications
    like Claude Desktop and VS Code extensions. Supports both Streamable HTTP
    and SSE transports with configurable authentication and CORS.
    """
  end

  defp package do
    [
      name: "conduit_mcp",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "MCP Specification" => "https://modelcontextprotocol.io/specification/"
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "ConduitMcp",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/choosing_a_mode.md",
        "guides/endpoint_mode.md",
        "guides/dsl_mode.md",
        "guides/manual_mode.md",
        "guides/authentication.md",
        "guides/rate_limiting.md",
        "guides/multi_node_sessions.md",
        "guides/oban_tasks.md"
      ],
      groups_for_extras: [
        Changelog: ["CHANGELOG.md"],
        "Getting Started": [
          "guides/choosing_a_mode.md",
          "guides/endpoint_mode.md",
          "guides/dsl_mode.md",
          "guides/manual_mode.md"
        ],
        Features: [
          "guides/authentication.md",
          "guides/rate_limiting.md",
          "guides/multi_node_sessions.md",
          "guides/oban_tasks.md"
        ]
      ],
      groups_for_modules: [
        Core: [
          ConduitMcp,
          ConduitMcp.Server,
          ConduitMcp.DSL,
          ConduitMcp.DSL.Helpers,
          ConduitMcp.DSL.SchemaBuilder
        ],
        "Endpoint Mode": [
          ConduitMcp.Endpoint,
          ConduitMcp.Component,
          ConduitMcp.Component.Schema
        ],
        "Protocol & Handler": [
          ConduitMcp.Protocol,
          ConduitMcp.Handler,
          ConduitMcp.Errors
        ],
        Transport: [
          ConduitMcp.Transport.StreamableHTTP,
          ConduitMcp.Transport.SSE
        ],
        Authentication: [
          ConduitMcp.Plugs.Auth,
          ConduitMcp.Plugs.OAuth,
          ConduitMcp.OAuth.KeyProvider,
          ConduitMcp.OAuth.KeyProvider.JWKS,
          ConduitMcp.OAuth.KeyProvider.Static,
          ConduitMcp.OAuth.ResourceMetadata
        ],
        "Rate Limiting": [
          ConduitMcp.Plugs.RateLimit,
          ConduitMcp.Plugs.MessageRateLimit
        ],
        Sessions: [
          ConduitMcp.Session,
          ConduitMcp.Session.Store,
          ConduitMcp.Session.EtsStore
        ],
        Tasks: [
          ConduitMcp.Tasks
        ],
        Client: [
          ConduitMcp.Client
        ],
        Validation: [
          ConduitMcp.Validation,
          ConduitMcp.Validation.SchemaConverter,
          ConduitMcp.Validation.Validators
        ],
        Observability: [
          ConduitMcp.Telemetry,
          ConduitMcp.PromEx
        ]
      ]
    ]
  end
end
