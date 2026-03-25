defmodule ConduitMcp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Seed validation config into persistent_term for O(1) reads on every request
    config = Application.get_env(:conduit_mcp, :validation, [])
    :persistent_term.put({ConduitMcp, :validation_config}, config)

    children = []

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConduitMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
