defmodule ConduitMcp.MixProject do
  use Mix.Project

  @version "0.10.1"
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
      # `dev/` carries Mix.Tasks.Bench, which is compiled only in :dev and is
      # what still needs :mix in the PLT.
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # `dev/` is deliberately outside `lib/`: `package.files` ships `lib`
  # wholesale, so a Mix task under `lib/` is packaged, compiled into the
  # consumer's :prod build, and shows up in their `mix help`. Keeping it in
  # `dev/` means `mix bench` still works here and ships nowhere.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
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

      # Optional: HTTP client for JWKS key fetching (only needed for JWKS key provider).
      # 0.6.1 is a security floor: earlier versions carry an unbounded-
      # decompression advisory the JWKS provider can reach. Expressed as a
      # union rather than `"~> 0.6 and >= 0.6.1"`, which resolves to `< 0.7.0`
      # and would exclude the version this repo itself locks.
      {:req, "~> 0.6.1 or ~> 0.7", optional: true},

      # Optional: OAuth 2.1 JWT validation (only needed if using :oauth auth strategy)
      {:joken, "~> 2.6", optional: true},
      {:jose, "~> 1.11", optional: true},

      # Development
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},

      # Security & audit
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},

      # Property-based testing
      {:stream_data, "~> 1.1", only: :test, runtime: false},

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
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "MCP Specification" => "https://modelcontextprotocol.io/specification/"
      },
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
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
        "guides/oban_tasks.md",
        "guides/mcp_apps.md"
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
          "guides/oban_tasks.md",
          "guides/mcp_apps.md"
        ]
      ],
      groups_for_modules: [
        Core: [
          ConduitMcp,
          ConduitMcp.Application,
          ConduitMcp.Server,
          ConduitMcp.DSL,
          ConduitMcp.DSL.Helpers,
          ConduitMcp.DSL.SchemaBuilder,
          ConduitMcp.OptionalDeps,
          ConduitMcp.OptionalDependencyError,
          ConduitMcp.Principal
        ],
        "Endpoint Mode": [
          ConduitMcp.Endpoint,
          ConduitMcp.Component,
          ConduitMcp.Component.Schema
        ],
        "Protocol & Handler": [
          ConduitMcp.Protocol,
          ConduitMcp.Handler,
          ConduitMcp.Errors,
          ConduitMcp.Cancellation
        ],
        Transport: [
          ConduitMcp.Transport.StreamableHTTP,
          ConduitMcp.Transport.SSE,
          ConduitMcp.Transport.Shared
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
        Security: [
          ConduitMcp.Plugs.OriginValidation,
          ConduitMcp.Plugs.SecurityHeaders
        ],
        Sessions: [
          ConduitMcp.Session,
          ConduitMcp.Session.Store,
          ConduitMcp.Session.EtsStore,
          ConduitMcp.Session.Janitor
        ],
        Tasks: [
          ConduitMcp.Tasks,
          ConduitMcp.Tasks.Store,
          ConduitMcp.Tasks.EtsStore,
          ConduitMcp.Tasks.Janitor
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
