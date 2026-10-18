if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.Transport.StreamableHTTP.Listener do
    @moduledoc false

    # The legacy standalone GET stream of
    # `ConduitMcp.Client.Transport.StreamableHTTP`: one process per legacy
    # session (under the client's `Task.Supervisor`, monitored by the
    # connection) that GETs the endpoint with `Accept: text/event-stream`
    # and passes what arrives to the connection - notifications, and server
    # requests (`related: nil`, answered by the connection's one dispatcher
    # through `respond/2`).
    #
    #   * `405`, or a `200` that is not an event stream (this library's own
    #     server answers a GET with an info document), means the server
    #     offers no such stream: the listener reports
    #     `{:listener_disabled, reason}` and stops; the transport does not
    #     start another for the session. So do a `404` (the session is gone:
    #     the next POST renews it) and `401`/`403`.
    #   * A drop (end of stream, network error, idle timeout) reopens the
    #     stream after the server's `retry:` (else a backoff from 1 s,
    #     doubling to 30 s), resuming with `Last-Event-ID` when an event id
    #     was seen. Any other status backs off the same way.
    #
    # Modern `subscriptions/listen` streams are not served here: the
    # connection sends them as requests (see the Exchange's `:listen` mode).

    alias ConduitMcp.Client.SSE
    alias ConduitMcp.Client.Transport.StreamableHTTP.Exchange

    @base_delay 1_000
    @max_delay 30_000

    @doc "Runs the GET stream described by `spec` until it is disabled or killed."
    @spec run(map()) :: :ok
    def run(spec), do: loop(spec, %{attempt: 0, last_event_id: nil})

    defp loop(spec, st) do
      case connect(spec, st) do
        {:disabled, reason} ->
          send(
            spec.owner,
            {spec.tag, spec.tref, spec.xref, :done, [{:listener_disabled, reason}]}
          )

          :ok

        {:dropped, st, retry} ->
          wait(delay(retry, st.attempt))
          loop(spec, %{st | attempt: st.attempt + 1})
      end
    end

    defp connect(spec, st) do
      headers =
        spec.headers ++
          spec.session_headers ++
          if(st.last_event_id, do: [{"last-event-id", st.last_event_id}], else: [])

      case Exchange.open(spec, :get, headers, nil) do
        {:ok, response} -> answer(response, spec, st)
        {:error, _reason} -> {:dropped, st, nil}
      end
    end

    defp answer(response, spec, st) do
      status = response.status
      type = spec.http.media_type(response)

      cond do
        status == 200 and type == "text/event-stream" ->
          sse =
            SSE.new(
              max_line_bytes: spec.max_bytes,
              max_event_bytes: spec.max_bytes,
              last_event_id: st.last_event_id
            )

          read(response, spec, st, sse)

        status in 200..299 ->
          spec.http.cancel(response)
          {:disabled, :not_an_event_stream}

        status in [401, 403, 404, 405] ->
          spec.http.cancel(response)
          {:disabled, {:http_status, status}}

        true ->
          spec.http.cancel(response)
          {:dropped, st, nil}
      end
    end

    defp read(response, spec, st, sse) do
      case spec.http.next(response) do
        {:data, data, response} ->
          case SSE.feed(sse, data) do
            {:ok, events, sse} ->
              forward(events, spec)
              # Traffic on an open stream: the next drop starts the backoff over.
              read(response, spec, %{st | attempt: 0}, sse)

            {:error, :event_too_large, sse} ->
              spec.http.cancel(response)
              {:dropped, %{st | last_event_id: SSE.last_event_id(sse)}, SSE.retry(sse)}
          end

        _done_or_error ->
          {:dropped, %{st | last_event_id: SSE.last_event_id(sse)}, SSE.retry(sse)}
      end
    end

    defp forward(events, spec) do
      messages =
        Enum.flat_map(events, fn event ->
          case JSON.decode(event.data) do
            {:ok, %{"method" => method, "id" => id} = message} when is_binary(method) ->
              [{:server_request, id, message, nil}]

            {:ok, %{"method" => method} = message} when is_binary(method) ->
              [{:notification, method, Map.get(message, "params") || %{}}]

            _other ->
              []
          end
        end)

      if messages != [],
        do: send(spec.owner, {spec.tag, spec.tref, spec.xref, :events, messages})
    end

    defp delay(retry, _attempt) when is_integer(retry), do: retry |> max(10) |> min(@max_delay)
    defp delay(nil, attempt), do: min(@base_delay * Integer.pow(2, min(attempt, 5)), @max_delay)

    defp wait(ms) do
      receive do
      after
        ms -> :ok
      end
    end
  end
end
