defmodule ConduitMcp.Client.Transport do
  @moduledoc """
  The behaviour a client transport implements.

  A transport moves JSON-RPC messages between a `ConduitMcp.Client.Connection`
  and one MCP server. Its callbacks run **inside the connection process**,
  and its state is plain data the connection holds and threads through every
  call (the "process-less" style of Mint). A transport may start helper
  processes of its own (a port owner, one process per in-flight HTTP request)
  under the client's `Task.Supervisor` or linked to the connection, but it
  never blocks: every callback returns promptly, and anything that takes
  time reports back later as a message that `c:handle_info/2` turns into
  events.

  ## Lifecycle

    0. `c:validate_options/1` (optional) - checks the options without side
       effects when `ConduitMcp.Client.Config.new!/1` runs, so a bad option
       raises an `ArgumentError` naming it in `child_spec/1` or
       `start_link/1` instead of failing the connection later. It returns
       the options `c:init/2` will get (with defaults filled in).
    1. `c:init/2` - once per connection attempt. Validates options and builds
       the state; no I/O. The first call happens while the client starts, so
       an `{:error, reason}` there fails `ConduitMcp.Client.start_link/1`.
    2. `c:connect/1` - starts connecting without waiting. The transport
       reports `{:connected, info}` once it can carry messages (an
       in-process or HTTP transport may report it at once) or
       `{:closed, reason}` if it cannot.
    3. `c:request/4`, `c:notify/2`, `c:respond/2`, `c:cancel/4` while
       connected; `c:handle_info/2` for every message the connection does not
       recognise as its own.
    4. `c:close/2` - when the connection reconnects, closes or stops. The
       state is discarded afterwards; the next attempt starts at `c:init/2`.

  ## Requests

  `c:request/4` gets a complete JSON-RPC request map (string keys, an
  integer `"id"` that the connection never reuses, `"params"` already
  carrying the era's `_meta`). It returns a `handle` (any term, for example
  the pid of the process sending it, or `nil`) that the connection passes
  back to `c:cancel/4`.

  The answer arrives as one of:

    * `{:response, id, message}` - the JSON-RPC response map (a `"result"` or
      an `"error"` member). The connection forwards it to the caller.
    * `{:exchange_done, id, :ok}` - the transport already delivered the
      response straight to the caller's alias: `send(reply_to, {reply_to,
      {:response, message}})` with the `reply_to` reference it was given.
      Only an HTTP-style transport that streams responses from a helper
      process does this; `reply_to` is `nil` for the connection's own
      requests (handshake, health checks), whose response must come back as
      `{:response, id, message}`.
    * `{:exchange_done, id, {:error, reason}}` - the request failed without a
      response; the caller gets `%ConduitMcp.Client.Error{kind: :transport,
      reason: reason}`. For the `server/discover` probe (`wire_opts[:probe]`
      is `true`) an `:http` transport reports a non-2xx answer as
      `{:error, {:http, status, content_type, body}}` and a network failure
      as `{:error, {:transport_error, reason}}`, so the connection can apply
      `ConduitMcp.Client.Negotiation.classify_probe/3`.

  `wire_opts` is a keyword list; the keys defined today are `:probe` (see
  above). Unknown keys must be ignored.

  ## Cancellation (`c:cancel/4`)

  Called when the caller's deadline passes (`reason` `:timeout`), the caller
  dies (`:caller_down`) or gives up (`:caller_timeout`). The transport does
  what the era and binding require:

    * stdio, both eras: send `notifications/cancelled` with the `requestId`.
    * modern HTTP: close the request's response stream; send nothing.
    * legacy HTTP: POST `notifications/cancelled`, then close the stream.
    * in-process: terminate the request's task.

  A response that still arrives after a cancel is dropped by the connection.
  `c:set_session/2` tells the transport which era it is serving.

  ## Events from `c:handle_info/2`

    * `{:connected, info}` - see `c:connect/1`.
    * `{:response, id, message}`, `{:exchange_done, id, outcome}` - above.
    * `{:notification, method, params}` - a server notification.
      `notifications/progress` is routed to the request whose id equals its
      `progressToken`; the rest go to the client's notification subscribers.
    * `{:server_request, id, message, related}` - a legacy server-to-client
      request; `related` is the id of the client request it belongs to, or
      `nil`. The connection answers it through `c:respond/2`, which a
      transport emitting this event must implement.
    * `{:closed, reason}` - the transport can no longer carry messages; the
      connection fails every pending request and reconnects.

  Return `:unknown` for a message that is not the transport's.

  ## Kinds

  `c:kind/0` names the transport family. It selects the evidence
  `ConduitMcp.Client.Negotiation.classify_probe/3` uses when probing for the
  protocol era (`:http` uses the HTTP rules, every other kind the stdio
  rules: a timeout or a non-modern error means a legacy server), the
  default `:probe_timeout` (5 s for `:http`, 3 s otherwise), and the
  `transport` value in telemetry metadata.
  """

  @typedoc "Transport state, owned by the connection."
  @type state :: term()

  @typedoc "A client request id: a positive integer, never reused."
  @type id :: pos_integer()

  @typedoc "What `c:init/2` receives besides its options."
  @type init_context :: %{owner: pid(), task_sup: pid(), key: term()}

  @type event ::
          {:connected, map()}
          | {:response, id :: term(), message :: map()}
          | {:exchange_done, id(), :ok | {:error, term()}}
          | {:notification, method :: String.t(), params :: map()}
          | {:server_request, id :: term(), message :: map(), related :: id() | nil}
          | {:closed, reason :: term()}

  @doc "The transport family; see the moduledoc."
  @callback kind() :: :stdio | :http | :in_process

  @doc """
  Checks `opts` without side effects; see "Lifecycle" in the moduledoc. The
  error message names the offending key.
  """
  @callback validate_options(opts :: keyword()) :: {:ok, keyword()} | {:error, String.t()}

  @doc "Validates `opts` and builds the transport state. Must not block."
  @callback init(opts :: keyword(), init_context()) :: {:ok, state()} | {:error, term()}

  @doc "Starts connecting; reports `{:connected, info}` or `{:closed, reason}` later."
  @callback connect(state()) :: {:ok, state()}

  @doc "Sends one request; see \"Requests\" in the moduledoc."
  @callback request(
              state(),
              message :: map(),
              reply_to :: reference() | nil,
              wire_opts :: keyword()
            ) ::
              {:ok, handle :: term(), state()} | {:error, reason :: term(), state()}

  @doc "Sends one client notification (no response expected)."
  @callback notify(state(), message :: map()) :: {:ok, state()} | {:error, term(), state()}

  @doc "Sends the client's response to a `{:server_request, ...}` event."
  @callback respond(state(), message :: map()) :: {:ok, state()} | {:error, term(), state()}

  @doc "Cancels an in-flight request; see \"Cancellation\" in the moduledoc."
  @callback cancel(state(), id(), handle :: term(), reason :: term()) :: {:ok, state()}

  @doc """
  Tells the transport the negotiated session: `%{era: :modern | :legacy,
  version: String.t()}`. Called each time the connection becomes ready.
  """
  @callback set_session(state(), session :: %{era: :modern | :legacy, version: String.t()}) ::
              state()

  @doc "Turns a message delivered to the connection into transport events."
  @callback handle_info(message :: term(), state()) :: {:ok, [event()], state()} | :unknown

  @doc "Releases everything the transport holds. Bounded by the connection's shutdown."
  @callback close(state(), reason :: term()) :: :ok

  @optional_callbacks respond: 2, set_session: 2, validate_options: 1
end
