defmodule LlmAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :llm_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      # The HTTP server is the simple_tools_server example, compiled in so
      # the agent can serve it locally (see LlmAgent.Application). Mix
      # takes an external source directory only as an absolute path.
      elixirc_paths: ["lib", Path.expand("../simple_tools_server", __DIR__)],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {LlmAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:conduit_mcp, path: "../.."},
      # The client's Streamable HTTP transport needs :finch.
      {:finch, "~> 0.21"},
      {:bandit, "~> 1.13"},
      # The Anthropic Messages API calls.
      {:req, "~> 0.6.1 or ~> 0.7"}
    ]
  end
end
