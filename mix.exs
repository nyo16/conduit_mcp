defmodule ConduitMcp.MixProject do
  use Mix.Project

  @version "0.11.1"
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
      # Called directly (`Plug.Crypto.secure_compare/2`). 2.2.1 is a security
      # floor: earlier releases carry EEF-CVE-2026-105963 (a wrong-typed argument
      # puts the secret in the stack trace). This library only passes binaries,
      # but the consumer's own `Plug.Crypto`/`Phoenix.Token` calls share the package.
      {:plug_crypto, "~> 2.2 and >= 2.2.1"},
      # 1.14.1 is a security floor. 1.13.1 carries twelve advisories published
      # 2026-10-26/28, ten of them HIGH and most reachable before authentication:
      # EEF-CVE-2026-111101 and -116078 (1-byte chunks / DATA frames behind
      # `Plug.Parsers`), -113436 (quadratic Content-Length parsing), -108525,
      # -108529, -109584, -110499, -111103 and -115269 (HTTP/2 flow control, HPACK
      # and SETTINGS), -114216 (chunk-extension request smuggling). 1.14.0 fixes
      # eleven; 1.14.1 is the first release clear of -116078.
      {:bandit, "~> 1.14 and >= 1.14.1"},
      {:nimble_options, "1.1.1"},

      # Optional: Rate limiting (only needed if using ConduitMcp.Plugs.RateLimit)
      {:hammer, "~> 7.2", optional: true},

      # Optional: Prometheus metrics via PromEx
      {:prom_ex, "~> 1.11", optional: true},
      # Not used directly: prom_ex -> octo_fetch declares it. Declared only to put
      # a security floor under it: 1.1.0-1.1.7 carry EEF-CVE-2026-117666 (CRITICAL,
      # a partial-label wildcard matches across a label boundary). `optional: true`
      # adds nothing for consumers without prom_ex.
      {:ssl_verify_fun, "~> 1.1 and >= 1.1.8", optional: true},

      # Optional: HTTP client for JWKS key fetching (only needed for JWKS key provider).
      # 0.6.1 is a security floor: earlier versions carry an unbounded-
      # decompression advisory the JWKS provider can reach. `~> 0.6` admits
      # every 0.x release from 0.6.0 on, 0.7.x included.
      {:req, "~> 0.6 and >= 0.6.1", optional: true},

      # Optional: HTTP for ConduitMcp.Client (Streamable HTTP transport and the
      # OAuth client). Used directly rather than through Req: Req's
      # `into: :self` blocks in a bare `receive` with no timeout, and
      # `Req.Test` cannot model a streamed response.
      {:finch, "~> 0.21", optional: true},
      # Used directly by the OAuth client's pinned-address connection
      # (`Mint.HTTP1`), and as Finch's stack. 1.11 is a security floor: 1.10.x
      # carries EEF-CVE-2026-91043 (HIGH, HPACK-indexed cookies bypass
      # `max_header_list_size`), EEF-CVE-2026-92103 and EEF-CVE-2026-94194.
      # `optional: true` adds nothing for consumers without Finch.
      {:mint, "~> 1.11", optional: true},

      # Optional: JSON Schema 2020-12 validation for ConduitMcp.Client's opt-in
      # `validate:` option (tool arguments and structured results).
      # 0.26.2 is a security floor: 0.26.0-0.26.1 carry EEF-CVE-2026-117680 (a
      # regex that exhausts its match budget counts as a non-match, so data can
      # skip `patternProperties` and `not`).
      {:jsv, "~> 0.26 and >= 0.26.2", optional: true},

      # Optional: OAuth 2.1 JWT validation (only needed if using :oauth auth strategy)
      {:joken, "~> 2.6", optional: true},
      # 1.11.13 is a security floor: 1.11.0-1.11.12 carry EEF-CVE-2026-65625 to
      # -65632. Two sit on the path this library uses: -65632 (ES256/384/512
      # signatures of a non-canonical length verify) and -65631 (an RSA JWK with
      # `d` but no CRT values is factored on parse; JWKS keys reach
      # `JOSE.JWK.from_map/1`).
      {:jose, "~> 1.11 and >= 1.11.13", optional: true},

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
    Elixir Model Context Protocol (MCP) library. Dual-era servers speak MCP
    2026-07-28 and 2025-11-25/2025-06-18 on one endpoint, with auth and rate
    limiting. Includes a governed MCP client: stdio and Streamable HTTP, a
    multi-server hub, LLM adapters and OAuth 2.1.
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
        "guides/tasks_extension.md",
        "guides/client.md",
        "guides/client_permissions_and_hooks.md",
        "guides/client_hub.md",
        "guides/client_llm_adapters.md",
        "guides/client_oauth.md",
        "guides/client_security.md"
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
        ],
        Client: [
          "guides/client.md",
          "guides/client_permissions_and_hooks.md",
          "guides/client_hub.md",
          "guides/client_llm_adapters.md",
          "guides/client_oauth.md",
          "guides/client_security.md"
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
          ConduitMcp.Principal,
          ConduitMcp.Reflect
        ],
        Supervision: [
          ConduitMcp.EtsOwner,
          ConduitMcp.Cancellation.Owner,
          ConduitMcp.Cancellation.InFlightOwner,
          ConduitMcp.Session.EtsStore.Owner,
          ConduitMcp.Tasks.EtsStore.Owner,
          ConduitMcp.Transport.SSE.Owner,
          ConduitMcp.Transport.SSEStream.Owner,
          ConduitMcp.Ext.Tasks.EtsStore.Owner,
          ConduitMcp.OAuth.KeyProvider.JWKS.Owner
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
        "Modern era (2026-07-28)": [
          ConduitMcp.Ctx,
          ConduitMcp.Era,
          ConduitMcp.Headers,
          ConduitMcp.Discover,
          ConduitMcp.Protocol.Modern,
          ConduitMcp.Plugs.HeaderValidation,
          ConduitMcp.MRTR,
          ConduitMcp.MRTR.State,
          ConduitMcp.Notifications,
          ConduitMcp.Subscriptions,
          ConduitMcp.Subscriptions.Filter,
          ConduitMcp.CacheHints,
          ConduitMcp.StreamSpec,
          ConduitMcp.Progress,
          ConduitMcp.Log,
          ConduitMcp.Transport.SSEStream
        ],
        "Tasks extension (experimental)": [
          ConduitMcp.Ext.Tasks,
          ConduitMcp.Ext.Tasks.Store,
          ConduitMcp.Ext.Tasks.EtsStore,
          ConduitMcp.Ext.Tasks.Notifier,
          ConduitMcp.Ext.Tasks.ListenNotifier
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
        "Tasks (legacy)": [
          ConduitMcp.Tasks,
          ConduitMcp.Tasks.Store,
          ConduitMcp.Tasks.EtsStore,
          ConduitMcp.Tasks.Janitor
        ],
        "Client: Core": [
          ConduitMcp.Client,
          ConduitMcp.Client.Config,
          ConduitMcp.Client.Connection,
          ConduitMcp.Client.Request,
          ConduitMcp.Client.Request.MRTR,
          ConduitMcp.Client.Registry,
          ConduitMcp.Client.Cache,
          ConduitMcp.Client.Handler,
          ConduitMcp.Client.Negotiation,
          ConduitMcp.Client.Backoff,
          ConduitMcp.Client.Secret,
          ConduitMcp.Client.Error,
          ConduitMcp.Client.Tool,
          ConduitMcp.Client.ToolCall,
          ConduitMcp.Client.ToolResult,
          ConduitMcp.Client.Resource,
          ConduitMcp.Client.Prompt,
          ConduitMcp.Client.Task,
          ConduitMcp.Client.DiscoverResult,
          ConduitMcp.Client.ServerInfo
        ],
        "Client: Transports": [
          ConduitMcp.Client.Transport,
          ConduitMcp.Client.Transport.InProcess,
          ConduitMcp.Client.Transport.Stdio,
          ConduitMcp.Client.Transport.Stdio.Framer,
          ConduitMcp.Client.Transport.StreamableHTTP,
          ConduitMcp.Client.SSE,
          ConduitMcp.Client.SSE.Event,
          ConduitMcp.Client.URLPolicy
        ],
        "Client: Governance": [
          ConduitMcp.Client.Pipeline,
          ConduitMcp.Client.Policy,
          ConduitMcp.Client.Policy.Decision,
          ConduitMcp.Client.Policy.Paths,
          ConduitMcp.Client.Hooks,
          ConduitMcp.Client.Grants,
          ConduitMcp.Client.ToolFilter,
          ConduitMcp.Client.Fingerprint,
          ConduitMcp.Client.SchemaValidator,
          ConduitMcp.Client.SchemaValidator.JSV
        ],
        "Client: Hub": [
          ConduitMcp.Client.Hub,
          ConduitMcp.Client.Hub.Config,
          ConduitMcp.Client.ToolSet,
          ConduitMcp.Client.Naming
        ],
        "Client: Adapters": [
          ConduitMcp.Client.Adapters,
          ConduitMcp.Client.Adapters.Anthropic,
          ConduitMcp.Client.Adapters.OpenAI,
          ConduitMcp.Client.Adapters.Gemini
        ],
        "Client: OAuth": [
          ConduitMcp.Client.OAuth,
          ConduitMcp.Client.OAuth.Config,
          ConduitMcp.Client.OAuth.TokenStore,
          ConduitMcp.Client.OAuth.TokenStore.ETS,
          ConduitMcp.Client.OAuth.Discovery,
          ConduitMcp.Client.OAuth.Discovery.Fetch,
          ConduitMcp.Client.OAuth.Registration,
          ConduitMcp.Client.OAuth.CIMD,
          ConduitMcp.Client.OAuth.ClientCredentials,
          ConduitMcp.Client.OAuth.Loopback,
          ConduitMcp.Client.OAuth.Pending,
          ConduitMcp.Client.OAuth.Callback,
          ConduitMcp.Client.OAuth.Challenge,
          ConduitMcp.Client.OAuth.PKCE,
          ConduitMcp.Client.OAuth.Resource,
          ConduitMcp.Client.OAuth.Scopes,
          ConduitMcp.Client.OAuth.Tokens,
          ConduitMcp.Client.OAuth.Error
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
