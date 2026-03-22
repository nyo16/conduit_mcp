defmodule McpAppsDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_apps_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {McpAppsDemo.Application, []}
    ]
  end

  defp deps do
    [
      # Point to the parent conduit_mcp library
      {:conduit_mcp, path: "../.."}
    ]
  end
end
