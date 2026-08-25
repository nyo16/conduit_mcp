defmodule ConduitMcp.Application do
  @moduledoc """
  OTP application for ConduitMCP.

  Request handling itself is stateless — each HTTP request runs in its own
  Bandit process — but ConduitMCP is **not** a library without processes. It
  starts a small supervision tree whose job is to own the long-lived ETS
  tables that must outlive short-lived request processes, plus the janitors
  that keep them bounded:

    * `ConduitMcp.Cancellation.Owner` — always started.
    * `ConduitMcp.Cancellation.Janitor` — always started; sweeps cancellation
      rows whose request never cleared them. Disable with
      `config :conduit_mcp, :cancellation_janitor, false`.
    * `ConduitMcp.Session.EtsStore.Owner` — always started.
    * `ConduitMcp.Transport.SSE.Owner` — always started; owns the
      concurrent-stream counter behind `Transport.SSE`'s `:max_connections`.
    * `ConduitMcp.Session.Janitor` — always started against
      `ConduitMcp.Session.EtsStore`, under the name
      `ConduitMcp.Session.Janitor.Default` so it cannot collide with a janitor
      you start yourself. Disable with
      `config :conduit_mcp, :session_janitor, false`, or tune it with
      `config :conduit_mcp, :session_janitor, ttl: ..., interval: ...`.
    * `ConduitMcp.Tasks.EtsStore.Owner` — started only when the default
      in-memory tasks store is in use (skipped for a custom `:tasks_store`).
    * `ConduitMcp.OAuth.KeyProvider.JWKS.Owner` — started when the JWKS key
      provider is compiled in (i.e. when `Req` is available).

  Every table above is `:public`; the owners create the table and then idle.
  Reads and writes go directly to ETS from the calling process — the owners
  are not `handle_call` gateways and must not become ones.

  `start/2` also seeds the validation config into `:persistent_term` for O(1)
  reads on every request.
  """

  use Application

  alias ConduitMcp.Cancellation
  alias ConduitMcp.OAuth.KeyProvider
  alias ConduitMcp.Session
  alias ConduitMcp.Tasks

  @impl true
  def start(_type, _args) do
    # Seed validation config into persistent_term for O(1) reads on every request
    config = Application.get_env(:conduit_mcp, :validation, [])
    :persistent_term.put({ConduitMcp, :validation_config}, config)

    children =
      always_started() ++
        session_janitor() ++ cancellation_janitor() ++ tasks_children() ++ jwks_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConduitMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Own the cancellation and session ETS tables from long-lived processes so
  # concurrent Bandit request handlers don't race on `:ets.new/2` and — more
  # importantly — so the tables survive the exit of whichever request process
  # happened to touch them first.
  defp always_started do
    [Cancellation.Owner, Session.EtsStore.Owner, ConduitMcp.Transport.SSE.Owner]
  end

  # The session table is created by unauthenticated `initialize` requests and,
  # now that it is supervised, never dies on its own. A TTL sweep is therefore
  # not optional: without it the only bound is the row cap in
  # `ConduitMcp.Session.EtsStore.create/2`.
  #
  # The 30-minute default is `Session.Janitor`'s, not the transport's. A
  # consumer who set `session: [ttl: :timer.hours(4)]` on the transport gets
  # rows swept at 30 minutes anyway - shortest sweep wins, and the janitor
  # cannot see per-transport config. Configure the same TTL here, or `false` to
  # run your own janitor:
  #
  #     config :conduit_mcp, session_janitor: [ttl: :timer.hours(4)]
  #     config :conduit_mcp, session_janitor: false
  defp session_janitor do
    defaults = [store: Session.EtsStore, name: Session.Janitor.Default]

    janitor(:session_janitor, defaults, Session.Janitor.Default)
  end

  # `notifications/cancelled` is reachable unauthenticated, so a row whose
  # request crashed before `Cancellation.clear/2` ran would linger forever.
  # The row cap alone would then turn into a denial of service against
  # legitimate cancellations.
  defp cancellation_janitor do
    defaults = [
      store: Cancellation,
      ttl: :timer.minutes(5),
      interval: :timer.minutes(1),
      name: Cancellation.Janitor,
      # Not the session event: `Cancellation.cleanup/1` already emits
      # `[:conduit_mcp, :cancellation, :cleanup]` itself, so leaving the
      # janitor's default here would publish the same count twice, once under
      # an event name that says "session".
      telemetry_event: [:conduit_mcp, :cancellation, :janitor],
      noun: "expired cancellation rows"
    ]

    janitor(:cancellation_janitor, defaults, Cancellation.Janitor)
  end

  @doc false
  # `false` disables; `true` and `[]` both mean "run it with the defaults".
  # Without the `true` clause the obvious symmetric spelling raises
  # CaseClauseError inside `Application.start/2`, which the consumer sees as an
  # opaque `{:conduit_mcp, {:bad_return, ...}}` at boot with nothing pointing
  # at their config line.
  #
  # Public (but undocumented) so the config contract can be tested without
  # restarting the application.
  def janitor(key, defaults, id) do
    case Application.get_env(:conduit_mcp, key, []) do
      false ->
        []

      true ->
        [Supervisor.child_spec({Session.Janitor, defaults}, id: id)]

      opts when is_list(opts) ->
        [Supervisor.child_spec({Session.Janitor, Keyword.merge(defaults, opts)}, id: id)]

      other ->
        raise ArgumentError,
              "config :conduit_mcp, #{inspect(key)} accepts true, false or a keyword " <>
                "list of ConduitMcp.Session.Janitor options; got #{inspect(other)}"
    end
  end

  # When the default in-memory store is configured (or no store is
  # configured), also start the Tasks ETS owner. If the user has wired
  # a custom :tasks_store, skip — they don't need our table.
  defp tasks_children do
    if Application.get_env(:conduit_mcp, :tasks_store, Tasks.EtsStore) == Tasks.EtsStore do
      [Tasks.EtsStore.Owner]
    else
      []
    end
  end

  # The JWKS key provider compiles only when Req is available. When it does,
  # own its ETS cache from a supervised process so the cache is stable across
  # the short-lived request processes that touch it on every authenticated
  # call (without this, a concurrent request can hit an :ets ArgumentError
  # when the creating request process exits mid-operation).
  defp jwks_children do
    if Code.ensure_loaded?(KeyProvider.JWKS.Owner) do
      [KeyProvider.JWKS.Owner]
    else
      []
    end
  end
end
