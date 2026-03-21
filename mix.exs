defmodule ConduitMcp.MixProject do
  use Mix.Project

  @version "0.6.5"
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
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:jason, "~> 1.4"},
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
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
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
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "ConduitMcp",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Changelog: ["CHANGELOG.md"]
      ]
    ]
  end
end
