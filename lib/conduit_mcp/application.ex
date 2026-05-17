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

    # Own the cancellation ETS table from a long-lived process so
    # concurrent Bandit request handlers don't race on `:ets.new/2` (every
    # handler touches this table via Cancellation.clear/1 in a try/after).
    base_children = [ConduitMcp.Cancellation.Owner]

    # When the default in-memory store is configured (or no store is
    # configured), also start the Tasks ETS owner. If the user has wired
    # a custom :tasks_store, skip — they don't need our table.
    tasks_children =
      if Application.get_env(:conduit_mcp, :tasks_store, ConduitMcp.Tasks.EtsStore) ==
           ConduitMcp.Tasks.EtsStore do
        [ConduitMcp.Tasks.EtsStore.Owner]
      else
        []
      end

    children = base_children ++ tasks_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConduitMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
