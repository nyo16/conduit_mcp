defmodule ConduitMcp.Client.Error do
  @moduledoc """
  The single error type returned by the MCP client.

  Every client failure is `{:error, %ConduitMcp.Client.Error{}}`. A tool that
  ran and reported `isError: true` is **not** an error: it comes back as
  `{:ok, %ConduitMcp.Client.ToolResult{is_error: true}}`.

  ## Fields

    * `:kind` - one of the closed set in `kinds/0`; match on it.
    * `:reason` - a short machine-readable detail (an atom or a tagged tuple
      such as `{:jsonrpc, -32602}`); varies per kind.
    * `:data` - optional extra context (for example a JSON-RPC error's `data`,
      or the exception an input handler raised). It may hold server-supplied
      content, so `message/1` never renders it.

  ## Kinds

    * `:timeout` - the request deadline passed.
    * `:transport` - the transport failed (connection refused, bad HTTP status).
    * `:protocol` - the peer broke the protocol, or answered with a JSON-RPC error.
    * `:denied` - the policy or an approver refused the call.
    * `:not_found` - the tool, resource, or prompt is hidden or unknown.
    * `:hook` - a pre- or post-hook failed (fail closed).
    * `:unavailable` - the connection or its cache is gone.
    * `:closed` - the client was closed.
    * `:overloaded` - in-flight or queue limits were reached.
    * `:input_handler` - a `ConduitMcp.Client.Handler` callback failed during MRTR.
    * `:auth` - authorization is required or failed.
    * `:rate_limited` - the server or a local limiter rejected the request.
    * `:session_expired` - a legacy session ended and could not be renewed.
    * `:mrtr_round_limit` - an MRTR loop hit a round, input, or state cap.
    * `:pagination_cycle` - a list cursor repeated or a pagination cap was hit.
    * `:message_too_large` - a message exceeded the configured byte cap.
    * `:connection_down` - the connection process exited mid-request.

  ## Secrets

  `message/1` renders only the kind and the reason. Binary reasons are
  truncated and `ConduitMcp.Client.Secret` values inspect as
  `#Secret<redacted>`, so the message is safe to log.
  """

  @kinds [
    :timeout,
    :transport,
    :protocol,
    :denied,
    :not_found,
    :hook,
    :unavailable,
    :closed,
    :overloaded,
    :input_handler,
    :auth,
    :rate_limited,
    :session_expired,
    :mrtr_round_limit,
    :pagination_cycle,
    :message_too_large,
    :connection_down
  ]

  @max_reason_bytes 200

  @type kind ::
          :timeout
          | :transport
          | :protocol
          | :denied
          | :not_found
          | :hook
          | :unavailable
          | :closed
          | :overloaded
          | :input_handler
          | :auth
          | :rate_limited
          | :session_expired
          | :mrtr_round_limit
          | :pagination_cycle
          | :message_too_large
          | :connection_down

  @type t :: %__MODULE__{kind: kind(), reason: term(), data: term()}

  defexception [:kind, :reason, :data]

  @doc "Every valid `:kind`, in documentation order."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @doc """
  Builds an error, raising `ArgumentError` when `kind` is not in `kinds/0`.

      iex> ConduitMcp.Client.Error.new(:timeout, :deadline).kind
      :timeout
  """
  @spec new(kind(), term(), term()) :: t()
  def new(kind, reason \\ nil, data \\ nil)

  def new(kind, reason, data) when kind in @kinds,
    do: %__MODULE__{kind: kind, reason: reason, data: data}

  def new(kind, _reason, _data),
    do: raise(ArgumentError, "unknown ConduitMcp.Client.Error kind: #{inspect(kind)}")

  @doc """
  Builds a `:protocol` error from a JSON-RPC error object.

  The reason is `{:jsonrpc, code}`; the full object (string keys, including
  the server's `message` and `data`) is kept in `:data`. A malformed object
  gives reason `:invalid_error_object`.
  """
  @spec from_rpc_error(term()) :: t()
  def from_rpc_error(%{"code" => code} = error) when is_integer(code),
    do: new(:protocol, {:jsonrpc, code}, error)

  def from_rpc_error(error), do: new(:protocol, :invalid_error_object, error)

  @impl true
  def message(%__MODULE__{kind: kind, reason: nil}), do: "MCP client error (#{kind})"

  def message(%__MODULE__{kind: kind, reason: reason}),
    do: "MCP client error (#{kind}): #{format_reason(reason)}"

  defp format_reason(reason) when is_binary(reason), do: truncate(reason)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_reason(reason),
    do: reason |> inspect(limit: 10, printable_limit: @max_reason_bytes) |> truncate()

  defp truncate(text) when byte_size(text) <= @max_reason_bytes, do: text

  defp truncate(text),
    do: String.slice(text, 0, @max_reason_bytes) <> "…"
end
