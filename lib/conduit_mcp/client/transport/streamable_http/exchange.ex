if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.Transport.StreamableHTTP.Exchange do
    @moduledoc false

    # One HTTP exchange of `ConduitMcp.Client.Transport.StreamableHTTP`: a
    # process under the client's `Task.Supervisor`, monitored by the
    # connection, that POSTs one message and reads the answer.
    #
    # Modes:
    #
    #   * `:request` - a JSON-RPC request. The response goes straight to the
    #     caller's alias (`{reply_to, {:response, message}}`) and the
    #     connection gets `{:exchange_done, id, :ok}`; for the connection's
    #     own requests (`reply_to` nil) the connection gets `{:response, id,
    #     message}`. Notifications and legacy server requests found on an
    #     event stream go to the connection as they arrive.
    #   * `:listen` - a modern `subscriptions/listen`: a request with no
    #     total deadline, bounded by the idle timeout instead; its response
    #     (the server's graceful end) goes to the connection.
    #   * `:post` - a notification or a response to a server request:
    #     expects 202 (any 2xx); nothing is reported back.
    #
    # Every message to the connection is `{tag, tref, xref, :events | :done,
    # events}`; `:done` is the last. Events the transport consumes itself:
    # `{:session_id, sid}` (a legacy `initialize` answer's validated
    # `Mcp-Session-Id`) and `{:expired, spec}` (a legacy 404 to a request
    # that carried a session id).
    #
    # The process holds the request body and credentials; it is started
    # with a closure, so a crash report names no arguments.

    alias ConduitMcp.Client.Error
    alias ConduitMcp.Client.OAuth.Challenge
    alias ConduitMcp.Client.OAuth.Session, as: OAuthSession
    alias ConduitMcp.Client.Secret
    alias ConduitMcp.Client.SSE
    alias ConduitMcp.Client.Transport.StreamableHTTP
    alias ConduitMcp.Client.URLPolicy

    require Logger

    @max_resumes 5
    @default_retry 1_000
    @max_retry 30_000
    @max_session_id_bytes 1_024
    @max_error_body 65_536
    @sent_key {__MODULE__, :sent}

    @doc "Runs the exchange described by `spec` (see the transport's `spec/6`)."
    @spec run(map()) :: :ok
    def run(%{mode: :post} = spec) do
      case open(spec, :post, spec.headers, spec.body) do
        {:ok, response} ->
          if response.status not in 200..299 do
            Logger.debug("MCP server answered a client message with HTTP #{response.status}")
          end

          spec.http.cancel(response)

        {:error, reason} ->
          Logger.debug("MCP client message not delivered: #{inspect(reason_tag(reason))}")
      end

      done(spec, [])
    end

    def run(spec) do
      case open(spec, :post, spec.headers, spec.body) do
        {:ok, response} -> answer(response, spec)
        {:error, reason} -> fail(spec, reason)
      end
    end

    @doc false
    # A legacy session's DELETE under `server_url_policy: :public_only`,
    # vetted and pinned like any request; run in a task by the transport's
    # `close/2`. Any answer or failure is fine.
    @spec delete(map()) :: :ok
    def delete(spec) do
      case open(spec, :delete, spec.headers, nil) do
        {:ok, response} -> spec.http.cancel(response)
        {:error, _reason} -> :ok
      end
    end

    # --- opening ---------------------------------------------------------------

    @doc false
    # Opens `method` on the spec's URL with `headers` plus credentials,
    # after the URL policy check. Shared with the Listener.
    @spec open(map(), :get | :post | :delete, list(), iodata() | nil) ::
            {:ok, term()} | {:error, term()}
    def open(spec, method, headers, body) do
      with {:ok, pin} <- check_url(spec),
           {:ok, auth} <- credentials(spec, method) do
        request = %{
          method: method,
          url: spec.url,
          headers: auth ++ headers,
          body: body,
          finch: spec.finch,
          deadline: Map.get(spec, :deadline, :infinity),
          idle_timeout: Map.get(spec, :idle_timeout, :infinity),
          redirect: spec.redirect
        }

        spec.http.open(if pin, do: Map.put(request, :pin, pin), else: request)
      end
    end

    # `server_url_policy: :public_only`: resolve and vet the host here, then
    # connect to the first vetted address (W-S4) - the name is not resolved
    # again between the check and the connect.
    defp check_url(%{url_policy: %{check: check, pool: pool}} = spec) do
      case URLPolicy.check(spec.url, :public_only, check) do
        {:ok, %{addresses: [address | _]}} -> {:ok, %{address: address, pool: pool}}
        {:error, reason} -> {:error, {:url_policy, reason}}
      end
    end

    defp check_url(_spec), do: {:ok, nil}

    defp credentials(%{auth: nil}, _method), do: {:ok, []}

    defp credentials(%{auth: {:bearer, token}}, _method), do: authorization(token)

    # OAuth: the stored token, refreshed here first when it is about to
    # expire (this process, never the connection). Only the MCP server's
    # URL ever gets it. The fingerprint of what was sent lets the
    # connection tell, after a 401, whether the store holds a newer token.
    defp credentials(%{auth: {:oauth, %OAuthSession{} = session}}, _method) do
      case OAuthSession.bearer(session) do
        {:ok, nil} ->
          Process.put(@sent_key, nil)
          {:ok, []}

        {:ok, token} ->
          Process.put(@sent_key, OAuthSession.fingerprint(token))
          authorization(token)
      end
    rescue
      # A host token store that raised; what it raised is not reported.
      _error -> {:error, Error.new(:auth, :credentials_unavailable)}
    end

    # Not handed over by the connection yet: nothing to send.
    defp credentials(%{auth: {:oauth, _config}}, _method), do: {:ok, []}

    # The auth seam: user code, run here and never in the connection.
    defp credentials(%{auth: fun} = spec, method) when is_function(fun, 1) do
      case fun.(%{url: spec.url, method: method}) do
        {:ok, nil} ->
          {:ok, []}

        {:ok, token} when is_binary(token) or is_struct(token, Secret) ->
          authorization(token)

        {:error, reason} ->
          {:error, Error.new(:auth, :credentials_unavailable, reason)}

        _other ->
          {:error, Error.new(:auth, :invalid_auth_return)}
      end
    rescue
      error -> {:error, Error.new(:auth, :auth_function_raised, Exception.message(error))}
    end

    # A token Mint would refuse fails here, by `kind: :auth, reason:
    # :invalid_token` naming no value (`StreamableHTTP.bearer/1`).
    defp authorization(token) do
      with {:ok, header} <- StreamableHTTP.bearer(token), do: {:ok, [{"authorization", header}]}
    end

    # --- the answer ------------------------------------------------------------

    defp answer(response, spec) do
      status = response.status
      type = spec.http.media_type(response)

      cond do
        status in 200..299 and type == "text/event-stream" ->
          with :ok <- capture_session(response, spec), do: stream(response, spec)

        status in 200..299 and type == "application/json" ->
          with :ok <- capture_session(response, spec), do: json(response, spec)

        status in 200..299 ->
          spec.http.cancel(response)
          fail(spec, {:unexpected_status, status})

        spec.probe? and not (oauth?(spec) and status in [401, 403]) ->
          probe_failure(response, spec)

        status in [401, 403] ->
          unauthorized(response, spec)

        status == 404 and spec.session != nil ->
          spec.http.cancel(response)
          done(spec, [{:expired, %{spec | xref: nil}}])

        status == 429 ->
          spec.http.cancel(response)

          fail(
            spec,
            Error.new(:rate_limited, {:http_status, 429}, %{retry_after: retry_after(response)})
          )

        status in 400..499 ->
          error_body(response, spec)

        true ->
          spec.http.cancel(response)
          fail(spec, {:http_status, status})
      end
    end

    # The probe's evidence for `ConduitMcp.Client.Negotiation.classify_probe/3`.
    defp probe_failure(response, spec) do
      type = spec.http.header(response, "content-type")

      body =
        case spec.http.read_body(response, @max_error_body) do
          {:ok, body} -> body
          {:error, _reason} -> nil
        end

      done(spec, [{:exchange_done, spec.id, {:error, {:http, response.status, type, body}}}])
    end

    defp unauthorized(response, spec) do
      challenges =
        case Challenge.parse(spec.http.headers(response, "www-authenticate")) do
          {:ok, challenges} -> challenges
          {:error, _error} -> []
        end

      spec.http.cancel(response)
      info = %{status: response.status, challenges: challenges}
      info = if oauth?(spec), do: Map.put(info, :sent, Process.get(@sent_key)), else: info
      done(spec, [{:unauthorized, spec.id, info}])
    end

    defp oauth?(%{auth: {:oauth, _}}), do: true
    defp oauth?(_spec), do: false

    defp retry_after(response) do
      with value when is_binary(value) <- spec_header(response, "retry-after"),
           {seconds, ""} <- Integer.parse(String.trim(value)),
           true <- seconds >= 0 do
        seconds
      else
        _ -> nil
      end
    end

    defp spec_header(%{headers: headers}, name) do
      case List.keyfind(headers || [], name, 0) do
        {_name, value} -> value
        nil -> nil
      end
    end

    # A 4xx carrying a JSON-RPC error is that error (a modern -32022 or
    # -32601, for example); anything else is the status.
    defp error_body(response, spec) do
      with "application/json" <- spec.http.media_type(response),
           {:ok, body} <- spec.http.read_body(response, @max_error_body),
           {:ok, %{"error" => %{}} = message} <- JSON.decode(body) do
        deliver(spec, message)
      else
        _other ->
          spec.http.cancel(response)
          fail(spec, {:http_status, response.status})
      end
    end

    # HT-14: a legacy session id is 1..1024 visible ASCII characters.
    defp capture_session(response, %{capture_session?: true} = spec) do
      case spec.http.header(response, "mcp-session-id") do
        nil ->
          :ok

        sid ->
          if valid_session_id?(sid) do
            emit(spec, [{:session_id, sid}])
            :ok
          else
            spec.http.cancel(response)
            fail(spec, Error.new(:protocol, :invalid_session_id))
          end
      end
    end

    defp capture_session(_response, _spec), do: :ok

    @doc false
    @spec valid_session_id?(term()) :: boolean()
    def valid_session_id?(sid) when is_binary(sid) and byte_size(sid) in 1..@max_session_id_bytes,
      do: sid |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

    def valid_session_id?(_sid), do: false

    defp json(response, spec) do
      with {:ok, body} <- spec.http.read_body(response, spec.max_bytes),
           {:ok, %{} = message} <- decode(body),
           true <- response_for?(message, spec.id) do
        deliver(spec, message)
      else
        {:error, :message_too_large} ->
          fail(spec, Error.new(:message_too_large, :message_too_large))

        {:error, reason} ->
          fail(spec, reason)

        _other ->
          fail(spec, Error.new(:protocol, :invalid_response))
      end
    end

    defp decode(body) do
      case JSON.decode(body) do
        {:ok, %{} = message} -> {:ok, message}
        _other -> {:error, Error.new(:protocol, :invalid_json)}
      end
    end

    defp response_for?(%{"id" => id} = message, id),
      do: Map.has_key?(message, "result") or Map.has_key?(message, "error")

    # An error the server could not tie to a request (id null).
    defp response_for?(%{"id" => nil, "error" => %{}}, _id), do: true
    defp response_for?(_message, _id), do: false

    # --- event streams ---------------------------------------------------------

    defp stream(response, spec) do
      sse = SSE.new(max_line_bytes: spec.max_bytes, max_event_bytes: spec.max_bytes)
      read(response, spec, %{sse: sse, resumes: 0})
    end

    defp read(response, spec, st) do
      case spec.http.next(response) do
        {:data, data, response} ->
          case SSE.feed(st.sse, data) do
            {:ok, events, sse} ->
              st = %{st | sse: sse}

              case handle_events(events, spec, []) do
                :delivered -> spec.http.cancel(response)
                {:continue, spec} -> read(response, spec, st)
              end

            {:error, :event_too_large, _sse} ->
              spec.http.cancel(response)
              fail(spec, Error.new(:message_too_large, :message_too_large))
          end

        :done ->
          ended(spec, st, :stream_closed)

        {:error, reason} ->
          ended(spec, st, reason)
      end
    end

    defp handle_events([], spec, acc) do
      emit(spec, Enum.reverse(acc))
      {:continue, spec}
    end

    defp handle_events([event | rest], spec, acc) do
      case classify(event.data, spec) do
        {:response, message} ->
          emit(spec, Enum.reverse(acc))
          deliver(spec, message)
          :delivered

        {:event, event} when spec.relayed? == false ->
          # From now on the response follows the events through the
          # connection, so the caller sees them (progress) before it.
          handle_events(rest, %{spec | relayed?: true}, [event | acc])

        {:event, event} ->
          handle_events(rest, spec, [event | acc])

        :ignore ->
          handle_events(rest, spec, acc)
      end
    end

    defp classify(data, spec) do
      case JSON.decode(data) do
        {:ok, %{"method" => method, "id" => id} = message} when is_binary(method) ->
          if spec.era == :legacy,
            do: {:event, {:server_request, id, message, spec.id}},
            else: :ignore

        {:ok, %{"method" => method} = message} when is_binary(method) ->
          {:event, {:notification, method, Map.get(message, "params") || %{}}}

        {:ok, %{} = message} ->
          if response_for?(message, spec.id), do: {:response, message}, else: :ignore

        _other ->
          :ignore
      end
    end

    # The stream ended without the response. A legacy stream that carried an
    # event id is resumed with GET + Last-Event-ID after `retry`; a modern
    # one is a failure (it is never replayed).
    defp ended(spec, st, reason) do
      last_id = SSE.last_event_id(st.sse)

      if spec.era == :legacy and last_id != nil and st.resumes < @max_resumes do
        wait(SSE.retry(st.sse))
        resume(spec, %{st | resumes: st.resumes + 1}, last_id, reason)
      else
        fail(spec, reason)
      end
    end

    defp wait(retry) do
      ms = min(retry || @default_retry, @max_retry)

      receive do
      after
        ms -> :ok
      end
    end

    defp resume(spec, st, last_id, reason) do
      headers =
        [{"accept", "text/event-stream"}, {"last-event-id", last_id}] ++
          Enum.filter(spec.headers, fn {name, _value} ->
            name in ["mcp-protocol-version", "mcp-session-id"] or user_header?(name)
          end)

      with {:ok, response} <- open(spec, :get, headers, nil),
           200 <- response.status,
           "text/event-stream" <- spec.http.media_type(response) do
        # The resumed stream starts from the id it resumed from, so a second
        # drop resumes from there too.
        sse =
          SSE.new(
            max_line_bytes: spec.max_bytes,
            max_event_bytes: spec.max_bytes,
            last_event_id: last_id
          )

        read(response, spec, %{st | sse: sse})
      else
        {:error, _reason} -> fail(spec, reason)
        _status_or_type -> fail(spec, reason)
      end
    end

    defp user_header?(name) do
      name not in ["content-type", "accept", "mcp-method", "mcp-name"] and
        not String.starts_with?(name, "mcp-param-")
    end

    # --- outcomes ----------------------------------------------------------------

    # Straight to the caller - unless the stream already sent events through
    # the connection: then the response goes the same way, behind them.
    defp deliver(%{reply_to: nil} = spec, message),
      do: done(spec, [{:response, spec.id, message}])

    defp deliver(%{relayed?: true} = spec, message),
      do: done(spec, [{:response, spec.id, message}])

    defp deliver(%{reply_to: reply_to} = spec, message) do
      send(reply_to, {reply_to, {:response, message}})
      done(spec, [{:exchange_done, spec.id, :ok}])
    end

    defp fail(spec, reason) do
      reason =
        cond do
          spec.probe? and match?({:transport_error, _}, reason) -> reason
          spec.probe? -> {:transport_error, reason}
          reason == :message_too_large -> Error.new(:message_too_large, :message_too_large)
          true -> reason
        end

      done(spec, [{:exchange_done, spec.id, {:error, reason}}])
    end

    defp emit(_spec, []), do: :ok

    defp emit(spec, events),
      do: send(spec.owner, {spec.tag, spec.tref, spec.xref, :events, events})

    defp done(spec, events) do
      send(spec.owner, {spec.tag, spec.tref, spec.xref, :done, events})
      :ok
    end

    defp reason_tag(%Error{kind: kind}), do: kind
    defp reason_tag(reason) when is_tuple(reason), do: elem(reason, 0)
    defp reason_tag(reason), do: reason
  end
end
