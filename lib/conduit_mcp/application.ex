defmodule ConduitMcp.Application do
  @moduledoc """
  OTP application for ConduitMCP.

  Request handling itself is stateless — each HTTP request runs in its own
  Bandit process — but ConduitMCP is **not** a library without processes. It
  starts a small supervision tree whose job is to own the long-lived ETS
  tables that must outlive short-lived request processes, plus the janitors
  that keep them bounded:

    * `ConduitMcp.Cancellation.Owner` — always started.
    * `ConduitMcp.Cancellation.InFlightOwner` — always started; owns the
      in-flight table (one row per request being handled) that gates which
      cancellations are recorded.
    * `ConduitMcp.Cancellation.Janitor` — always started; sweeps cancellation
      rows whose request never cleared them, and in-flight rows whose process
      died without untracking. Disable with
      `config :conduit_mcp, :cancellation_janitor, false`.
    * `ConduitMcp.Session.EtsStore.Owner` — always started.
    * `ConduitMcp.Transport.SSE.Owner` — always started; owns the slot table
      (one row per live stream) behind `Transport.SSE`'s `:max_connections`.
    * `ConduitMcp.Transport.SSEStream.Owner` — always started; owns the slot
      table (one row per open stream) behind the HTTP transports'
      `:max_streams` cap on streamed POST responses.
    * `ConduitMcp.Subscriptions` — always started; a `Registry` (duplicate
      keys) of the `subscriptions/listen` streams served by this node, keyed
      by the notification topics they deliver. The registry's own processes
      only clean up after streams that die; publishing and registering go
      straight to its ETS tables from the calling process.
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

  It also starts `ConduitMcp.Client.Registry`, a passive unique `Registry`
  (partitioned by scheduler) in which every `ConduitMcp.Client` registers
  its processes under tuple keys of its `:name`. The application starts no
  client processes: you supervise `{ConduitMcp.Client, opts}` yourself.

  `start/2` also seeds the validation config into `:persistent_term` for O(1)
  reads on every request, and, when `config :conduit_mcp, :mrtr_keys` is set,
  validates that keyring with `ConduitMcp.MRTR.State.validate_keys!/1` so a
  malformed key fails at boot rather than on the first MRTR request.
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
    validate_mrtr_keys!()

    children =
      always_started() ++
        session_janitor() ++ cancellation_janitor() ++ tasks_children() ++ jwks_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ConduitMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only when configured: MRTR is opt-in, and `MRTR.State.seal/3` raises its own
  # clear error when a server uses it without keys.
  defp validate_mrtr_keys! do
    case Application.fetch_env(:conduit_mcp, :mrtr_keys) do
      {:ok, keys} -> ConduitMcp.MRTR.State.validate_keys!(keys)
      :error -> :ok
    end
  end

  # Own the cancellation, in-flight and session ETS tables from long-lived
  # processes so concurrent Bandit request handlers don't race on
  # `:ets.new/2` and — more importantly — so the tables survive the exit of
  # whichever request process happened to touch them first. The client
  # registry is passive: clients register in it, so names of any term need no
  # atoms (`ConduitMcp.Client.Registry` keys).
  defp always_started do
    [
      Cancellation.Owner,
      Cancellation.InFlightOwner,
      Session.EtsStore.Owner,
      ConduitMcp.Transport.SSE.Owner,
      ConduitMcp.Transport.SSEStream.Owner,
      {Registry,
       keys: :unique, name: ConduitMcp.Client.Registry, partitions: System.schedulers_online()},
      ConduitMcp.Subscriptions
    ]
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
  # legitimate cancellations. The same pass drops in-flight rows of request
  # processes killed before `Cancellation.untrack/2` ran.
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
