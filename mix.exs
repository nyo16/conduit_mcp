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
      # 1.20.3 is a security floor. `Plug.Parsers` runs before
      # authentication and always decodes the query string, so an older plug
      # hands unauthenticated callers CVE-2026-54892 (quadratic decoding of
      # nested params, 1.19.0-1.19.2); 1.19.x and 1.20.0-1.20.2 also carry
      # CVE-2026-56813 and CVE-2026-56814. 1.20.3 is the first release clear
      # of all of them.
      {:plug, "~> 1.20 and >= 1.20.3"},
      # 1.13.1 is a security floor. 1.12.5 carries EEF-CVE-2026-105659 (HIGH,
      # an HTTP/2 blocked-send deadline that every WINDOW_UPDATE resets, so a
      # trickling peer pins stream processes indefinitely) and
      # EEF-CVE-2026-105660 (MEDIUM, an unvalidated HTTP/1 request-target
      # authority lets the client choose `conn.host`/`conn.port`). Older
      # releases also carry CVE-2026-74836 and CVE-2026-75484.
      {:bandit, "~> 1.13 and >= 1.13.1"},
      # Not used directly: Bandit's HTTP/2 stack depends on it. Declared only
      # to put a security floor under it, since Bandit's own requirement still
      # admits hpax 1.0.0-1.0.3 (CVE-2026-58226, unauthenticated HPACK decoding
      # DoS). `optional: true` adds no dependency for consumers; Mix applies
      # this requirement whenever Bandit brings hpax in.
      {:hpax, "~> 1.0 and >= 1.0.4", optional: true},
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

      # Optional: HTTP for ConduitMcp.Client (Streamable HTTP transport and the
      # OAuth client). Used directly rather than through Req: Req's
      # `into: :self` blocks in a bare `receive` with no timeout, and
      # `Req.Test` cannot model a streamed response.
      {:finch, "~> 0.21", optional: true},
      # Not used directly: Finch's HTTP stack. Declared only to put a security
      # floor under it: 1.10.x carries EEF-CVE-2026-91043 (HIGH, HPACK-indexed
      # cookies bypass `max_header_list_size`), EEF-CVE-2026-92103 and
      # EEF-CVE-2026-94194. `optional: true` adds nothing for consumers.
      {:mint, "~> 1.11", optional: true},

      # Optional: JSON Schema 2020-12 validation for ConduitMcp.Client's opt-in
      # `validate:` option (tool arguments and structured results).
      {:jsv, "~> 0.26", optional: true},

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
        "guides/mcp_apps.md",
        "guides/protocol_eras.md",
        "guides/mrtr.md",
        "guides/subscriptions.md",
        "guides/tasks_extension.md"
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
        ],
        "Modern Protocol (2026-07-28)": [
          "guides/protocol_eras.md",
          "guides/mrtr.md",
          "guides/subscriptions.md",
          "guides/tasks_extension.md"
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
          ConduitMcp.Protocol.Legacy,
          ConduitMcp.Handler,
          ConduitMcp.Capabilities,
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
