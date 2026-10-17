defmodule ConduitMcp.Client.Handler do
  @moduledoc """
  The behaviour for answering a server's requests for input: sampling,
  elicitation and roots, plus optional notification and log hooks.

  One module serves both protocol eras:

    * **Legacy** (`2025-11-25`, `2025-06-18`): the server sends JSON-RPC
      requests (`sampling/createMessage`, `elicitation/create`, `roots/list`).
      Each runs in a supervised task with a timeout (`handler_timeout`:
      5 minutes for elicitation, 60 seconds otherwise), at most
      `max_server_requests` (8) at once (over the cap the server gets
      `-32000` busy). A server `notifications/cancelled` kills the task, and
      a crash answers `-32603`. A request tied to an in-flight call (`related`
      request id) pauses that call's deadline, bounded by its maximum.
    * **Modern** (`2026-07-28`): there are no server-to-client requests. A
      `tools/call`, `resources/read` or `prompts/get` may return
      `resultType: "input_required"` with `inputRequests`; the client calls
      this module **in the calling process** for every input request, then
      retries the original request with the answers (MRTR). A raise or an
      `{:error, _}` aborts the call with
      `%ConduitMcp.Client.Error{kind: :input_handler}`.

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

  ## Safety defaults applied around the callbacks

    * **Sampling** needs an approval hook; `maxTokens` is clamped to the
      configured client maximum (4096 by default); requests are rate limited
      per server; `includeContext` is coerced to `"none"` unless sampling
      context is enabled; a legacy sampling request with no related call is
      denied.
    * **Elicitation**: the client never fetches or opens a URL. For URL mode
      the context carries the full URL, its host, an `idn` flag and an
      origin-mismatch flag; only `https` is accepted. Form schemas are checked
      against the flat primitive subset, secret-looking fields are flagged,
      and responses are validated before they are sent. A mode that was not
      declared is refused with `-32602`.
    * **Roots** are per server and `file://` only.

  ## Context

  Every callback receives a context map. The client sets at least:

    * `:server_id` - the operator-assigned id of the asking server.
    * `:era` - `:modern` or `:legacy`.
    * `:assigns` - the `assigns` of the related call, or of the connection
      when the request is not tied to a call.
    * `:related_request_id` - the in-flight request this input belongs to,
      or `nil`.
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
