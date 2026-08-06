defmodule ConduitMcp.Application do
  @moduledoc """
  OTP application for ConduitMCP.

  ConduitMCP is largely stateless — each HTTP request runs in its own Bandit
  process — so the supervision tree is deliberately small. Its job is to own
  the few long-lived ETS tables that must outlive short-lived request
  processes:

    * `ConduitMcp.Cancellation.Owner` — always started.
    * `ConduitMcp.Tasks.EtsStore.Owner` — started only when the default
      in-memory tasks store is in use (skipped for a custom `:tasks_store`).
    * `ConduitMcp.OAuth.KeyProvider.JWKS.Owner` — started when the JWKS key
      provider is compiled in (i.e. when `Req` is available).

  It also seeds the validation config into `:persistent_term` for O(1) reads on
  every request.
  """

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

    # The JWKS key provider compiles only when Req is available. When it does,
    # own its ETS cache from a supervised process so the cache is stable across
    # the short-lived request processes that touch it on every authenticated
    # call (without this, a concurrent request can hit an :ets ArgumentError
    # when the creating request process exits mid-operation).
    jwks_children =
      if Code.ensure_loaded?(ConduitMcp.OAuth.KeyProvider.JWKS.Owner) do
        [ConduitMcp.OAuth.KeyProvider.JWKS.Owner]
      else
        []
      end

    children = base_children ++ tasks_children ++ jwks_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConduitMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
