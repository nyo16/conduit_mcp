defmodule ConduitMcp.Client.Handler do
  @moduledoc """
  The behaviour for answering a server's requests for input: sampling,
  elicitation and roots, plus optional notification and log hooks.

  One module serves both protocol eras:

    * **Legacy** (`2025-11-25`, `2025-06-18`): the server sends JSON-RPC
      requests (`sampling/createMessage`, `elicitation/create`, `roots/list`).
      Each runs in a task under the client's `Task.Supervisor`, never in the
      connection, killed after `:handler_timeout` (5 minutes for
      elicitation, 60 seconds otherwise) and answered `-32603`; at most
      `:max_server_requests` (8) run at once (over the cap the server gets
      `-32000` busy). A server `notifications/cancelled` kills the task, and
      a crash answers `-32603`. A request tied to an in-flight call (its
      `related` request id; on stdio, the one call in flight if there is
      exactly one) pauses that call's deadline, bounded by its
      `:max_total_timeout`, and gets that call's `:assigns`.
    * **Modern** (`2026-07-28`): there are no server-to-client requests. A
      `tools/call`, `resources/read` or `prompts/get` may return
      `resultType: "input_required"` with `inputRequests`; the client calls
      this module **in the calling process** for every input request, then
      retries the original request with the answers (MRTR). A raise or an
      `{:error, _}` aborts the call with
      `%ConduitMcp.Client.Error{kind: :input_handler}`. Input requests of a
      server task (`ConduitMcp.Client.await_task/3`) are answered the same
      way and sent with `tasks/update`.

  ## Capabilities come from the callbacks

  The client advertises only what this module implements (see
  `ConduitMcp.Client.Negotiation.client_capabilities/2`):

    * `handle_sampling/2` ⇒ `sampling`
    * `handle_elicitation/2` ⇒ `elicitation`, with the modes from
      `elicitation_modes/0` (default `[:form]`)
    * `list_roots/1` ⇒ `roots`

  No handler, or a handler with none of those callbacks, advertises nothing:
  `clientCapabilities` is `{}`. A server request or MRTR input request for an
  undeclared capability is refused before any callback runs (`-32601` for a
  legacy request, a `:protocol` error for MRTR).

  ## Results

  Callbacks return string-keyed maps shaped like the spec's result types:
  `{:ok, CreateMessageResult}`, `{:ok, ElicitResult}`, `{:ok, ListRootsResult}`.
  A legacy request may be refused with `{:error, %{"code" => integer,
  "message" => binary}}`, which is sent as the JSON-RPC error. A user who
  declines an elicitation is a result, not an error:
  `{:ok, %{"action" => "decline"}}`.

  ## Safety checks applied around the callbacks

  Both eras go through the same checks, before and after the callback:

    * **Budget**: input requests of one server are rate limited
      (`:input_rate_limit`, 10/s with bursts of 20).
    * **Sampling**: this callback is the approval point. `maxTokens` must be
      a positive integer and is clamped to `sampling: [max_tokens: _]`
      (4096); `includeContext` is coerced to `"none"` unless
      `sampling: [context: true]`; a legacy sampling request that arrives
      while no call is in flight is refused unless
      `sampling: [allow_idle: true]`; a request whose `messages` already
      hold more than `sampling: [max_tool_iterations: _]` (5) assistant
      `tool_use` turns is refused. Refusals (idle, tool loop, over budget)
      use `sampling: [rejection_code: _]` (default `-1`).
    * **Elicitation**: the client never fetches or opens a URL. A mode the
      handler does not declare is refused with `-32602`. URL mode accepts
      only absolute `https` URLs without userinfo (`javascript:`, `http:`,
      `file:` are refused with `-32602`); the context carries the full
      `:url`, its `:host`, `:idn?` (a punycode `xn--` label) and
      `:origin_mismatch?` (true unless the URL has the server's origin,
      which HTTP transports report and `elicitation: [origin: _]` sets;
      always true when unknown). Form schemas must be the spec's flat
      primitive subset (else `-32602`), and the context carries `:fields`,
      `%{name => %{sensitive_suspected: boolean}}` flagging secret-looking
      fields. Answers are validated before they are sent: `"action"` must be
      `"accept"`, `"decline"` or `"cancel"`, a form `accept` must fit the
      schema, a URL `accept` carries no content (else `-32603`).
    * **Roots** are asked per server (the context has `:server_id`); only
      `file://` URIs on the local host are sent, with `.`/`..` resolved.

  ## Notifications

  `handle_notification/3` and `handle_log/3` run in a process of their own,
  one notification at a time in arrival order; a raise is logged and
  skipped, and beyond 1 000 waiting notifications new ones are dropped.

  ## Context

  Every callback receives a context map (notification callbacks get only
  `:client`, `:server_id` and `:era`):

    * `:client` - the client's `:name`.
    * `:server_id` - the operator-assigned id of the asking server.
    * `:era` - `:modern` or `:legacy`.
    * `:assigns` - the `:assigns` of the related call, or the client's
      `:assigns` when the request is not tied to a call.
    * `:related_request_id` - the in-flight request this input belongs to,
      or `nil` (always `nil` for modern input).
    * Elicitation adds `:mode` (`:form` or `:url`) and the keys above.
  """

  @typedoc "Context passed to every callback; see the moduledoc for keys."
  @type ctx :: %{optional(atom()) => term()}

  @typedoc "An elicitation mode the handler can present."
  @type elicitation_mode :: :form | :url

  @typedoc "A JSON-RPC error object refusing a legacy request."
  @type rpc_error :: %{required(String.t()) => term()}

  @doc """
  Answers `sampling/createMessage` with a `CreateMessageResult` map.
  """
  @callback handle_sampling(params :: map(), ctx()) :: {:ok, map()} | {:error, rpc_error()}

  @doc """
  Answers `elicitation/create` with an `ElicitResult` map (`"action"` is
  `"accept"`, `"decline"` or `"cancel"`).
  """
  @callback handle_elicitation(params :: map(), ctx()) :: {:ok, map()} | {:error, rpc_error()}

  @doc """
  The elicitation modes this handler can present. Defaults to `[:form]` when
  not implemented. Only consulted when `handle_elicitation/2` is implemented.
  """
  @callback elicitation_modes() :: [elicitation_mode(), ...]

  @doc """
  Answers `roots/list` with a `ListRootsResult` map
  (`%{"roots" => [%{"uri" => "file:///...", "name" => ...}]}`).
  """
  @callback list_roots(ctx()) :: {:ok, map()} | {:error, rpc_error()}

  @doc """
  Called with every server notification the client does not consume itself
  (`method` and string-keyed `params`). The return value is ignored. It runs
  outside the connection process.
  """
  @callback handle_notification(method :: String.t(), params :: map(), ctx()) :: any()

  @doc """
  Called with each `notifications/message` log entry: `level` is the wire
  level string (`"debug"` … `"emergency"`), `params` the full params. The
  return value is ignored.
  """
  @callback handle_log(level :: String.t(), params :: map(), ctx()) :: any()

  @optional_callbacks handle_sampling: 2,
                      handle_elicitation: 2,
                      elicitation_modes: 0,
                      list_roots: 1,
                      handle_notification: 3,
                      handle_log: 3
end
