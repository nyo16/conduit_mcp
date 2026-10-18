defmodule ConduitMcp.StreamSpec do
  @moduledoc """
  A response the transport may send as a Server-Sent Events stream instead
  of a single JSON body: the `{:stream, spec}` reply of
  `ConduitMcp.Handler.dispatch/3`.

  The modern handler returns one of two kinds:

    * `:response` — a modern `tools/call` whose `_meta` carries a
      `progressToken` or `io.modelcontextprotocol/logLevel`: the requests
      that can receive `notifications/progress` or `notifications/message`
      while the tool runs.
    * `:listen` — a modern `subscriptions/listen` whose filter parsed: a
      long-lived stream of change notifications that has no response until
      the server ends it (`ConduitMcp.Subscriptions`).

  Every other request is answered `{:reply, response}`.

  A `:response` spec's `run` produces the final JSON-RPC response map. What
  runs it decides how the response travels:

    * `ConduitMcp.Transport.Shared.dispatch_post/2` runs it in a task and,
      while it runs, relays the tool's notifications (`ConduitMcp.Progress`,
      `ConduitMcp.Log`) as SSE events ahead of the response. A client that
      disconnects cancels the request (`ConduitMcp.Cancellation`).
    * `run/1` runs it in the calling process with no stream: notifications
      are dropped and the response is returned. `ConduitMcp.Handler.handle_request/3`
      uses it, so manual-mode callers keep getting a map.

  Either way the request is tracked in flight for `run`'s duration, so the
  tool can poll `ConduitMcp.Cancellation.cancelled?/1`.

  A `:listen` spec has no `run`: only a transport that can hold an SSE
  stream open serves it (`ConduitMcp.Transport.Shared.dispatch_post/2`).
  `ConduitMcp.Handler.handle_request/3` answers it `-32601`.
  """

  alias ConduitMcp.Handler.Pipeline
  alias ConduitMcp.Transport.SSEStream

  @enforce_keys [:conn]
  defstruct kind: :response,
            request_id: nil,
            method: nil,
            progress_token: nil,
            conn: nil,
            run: nil,
            subscription: nil

  @typedoc """
    * `:kind` — `:response`: a finite response, preceded by notifications;
      `:listen`: a `subscriptions/listen` stream.
    * `:request_id` — the JSON-RPC id being answered.
    * `:method` — the request method.
    * `:progress_token` — the request's `_meta.progressToken`, carried by
      every `notifications/progress`; `nil` when the request has none.
    * `:conn` — the conn `run` is called with (the request's
      `ConduitMcp.Ctx` is stored in it).
    * `:run` — `:response` only: `(Plug.Conn.t() -> map())`, the work:
      returns the JSON-RPC response map. It must not raise;
      the modern handler builds it around the same guard as every
      other request.
    * `:subscription` — `:listen` only: the honoured
      `ConduitMcp.Subscriptions.Filter`.
  """
  @type t :: %__MODULE__{
          kind: :response | :listen,
          request_id: ConduitMcp.Protocol.json_rpc_id() | nil,
          method: String.t() | nil,
          progress_token: String.t() | integer() | nil,
          conn: Plug.Conn.t() | map(),
          run: (Plug.Conn.t() | map() -> map()) | nil,
          subscription: ConduitMcp.Subscriptions.Filter.t() | nil
        }

  @sink :mcp_stream_sink

  @doc """
  Runs `spec` in the calling process, without a stream, and returns the
  response map. Notifications the work emits are dropped.
  """
  @spec run(t()) :: map()
  def run(%__MODULE__{kind: :response} = spec),
    do: Pipeline.in_flight(spec.conn, spec.request_id, spec.run)

  @doc false
  # Points `ConduitMcp.Progress` / `ConduitMcp.Log` on `conn` at the stream
  # served by `pid`: each notification becomes a
  # `{ConduitMcp.StreamSpec, ref, {:frame, iodata}}` message to it.
  @spec put_sink(Plug.Conn.t() | map(), pid(), reference(), String.t() | integer() | nil) ::
          Plug.Conn.t() | map()
  def put_sink(%{private: private} = conn, pid, ref, progress_token),
    do: %{conn | private: Map.put(private, @sink, {pid, ref, progress_token})}

  @doc false
  # Sends the notification `build` returns for the request's progress token
  # to the stream on `conn`, encoded here, in the caller — so a value that is
  # not JSON-encodable raises in the tool that produced it. A no-op when
  # `conn` has no stream (a JSON response, a legacy request) or `build`
  # returns `nil`.
  @spec notify(Plug.Conn.t() | map(), (String.t() | integer() | nil -> map() | nil)) :: :ok
  def notify(%{private: %{@sink => {pid, ref, progress_token}}}, build) do
    case build.(progress_token) do
      nil -> :ok
      message -> send(pid, {__MODULE__, ref, {:frame, SSEStream.frame(message)}})
    end

    :ok
  end

  def notify(_conn, _build), do: :ok
end
