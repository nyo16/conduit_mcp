if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.HTTP do
    @moduledoc false

    # Every HTTP request of the OAuth client - Protected Resource Metadata,
    # authorization-server metadata, dynamic client registration and token
    # requests - goes through `request/5`. None of them ever carries the MCP
    # server's bearer token; a token request may carry the client's own
    # credentials (`client_secret_basic`), nothing else.
    #
    # ## URL policy and IP pinning (HT-6)
    #
    # The URLs are server-supplied (a `resource_metadata` challenge
    # parameter, `authorization_servers`, metadata endpoints), so each one
    # passes `ConduitMcp.Client.URLPolicy` `:public_only` first: `https`
    # only, and the host is resolved once (A + AAAA) and refused if any
    # address is private, loopback, link-local or otherwise internal, unless
    # it falls in `:allow_private`.
    #
    # The connection then goes to exactly the vetted address: a dedicated
    # Mint connection (`Mint.HTTP.connect/4` with the IP tuple as the
    # address and `hostname:` set to the URL's host, so SNI, certificate
    # hostname verification and the `Host` header all use the original
    # name). Nothing resolves the name a second time, which closes the DNS
    # rebinding window between the check and the connect.
    #
    # This cannot be done through a Finch pool: Finch keys pools by
    # `{scheme, host, port}` of the request URL and fixes each pool's
    # connection options when the pool starts, then lets Mint resolve the
    # hostname itself on every new connection. Pinning one request to an
    # address needs per-request connection options, which a pool does not
    # take. So OAuth requests use one short-lived, unpooled connection each
    # (Mint is a dependency of Finch, so it is present whenever this module
    # is compiled). They are rare - discovery, registration, a token
    # exchange or refresh - so the lost reuse costs nothing that matters.
    #
    # ## Other guarantees
    #
    #   * No redirects: a 3xx is a failed request (HT-4); for discovery that
    #     means "try the next candidate".
    #   * `accept-encoding: identity`, and a response with any other
    #     `content-encoding` is refused before its body is read (HT-1).
    #   * The body is capped (`:max_bytes`, default 256 KiB) and the whole
    #     exchange is bounded by `:timeout` milliseconds.
    #   * `allow_insecure: true` (the `allow_insecure_oauth` option, for
    #     development and tests) admits plain `http` to a loopback host,
    #     connected by name with no address check. `https` URLs are always
    #     checked.

    alias ConduitMcp.Client.OAuth.URL
    alias ConduitMcp.Client.Secret
    alias ConduitMcp.Client.URLPolicy

    @default_max_bytes 262_144
    @default_timeout 10_000

    @type ctx :: %{
            optional(:allow_insecure) => boolean(),
            optional(:allow_private) => [term()],
            optional(:resolver) => URLPolicy.resolver() | nil,
            optional(:transport_opts) => keyword(),
            optional(:timeout) => pos_integer(),
            optional(:max_bytes) => pos_integer()
          }

    @type response :: %{
            status: non_neg_integer(),
            headers: [{String.t(), String.t()}],
            body: binary()
          }

    @type reason ::
            {:url_blocked, term()}
            | {:invalid_url, term()}
            | {:redirect, non_neg_integer()}
            | {:unsupported_content_encoding, String.t()}
            | :message_too_large
            | :timeout
            | {:transport_error, term()}

    @doc "A GET expecting JSON."
    @spec get(String.t(), ctx()) :: {:ok, response()} | {:error, reason()}
    def get(url, ctx), do: request("GET", url, [{"accept", "application/json"}], nil, ctx)

    @doc "A POST of a form body (`application/x-www-form-urlencoded`)."
    @spec post_form(String.t(), [{String.t(), String.t()}], [{String.t(), term()}], ctx()) ::
            {:ok, response()} | {:error, reason()}
    def post_form(url, form, headers, ctx) do
      body = URI.encode_query(form, :www_form)

      headers =
        [
          {"content-type", "application/x-www-form-urlencoded"},
          {"accept", "application/json"}
        ] ++ headers

      request("POST", url, headers, body, ctx)
    end

    @doc "A POST of a JSON body."
    @spec post_json(String.t(), map(), ctx()) :: {:ok, response()} | {:error, reason()}
    def post_json(url, map, ctx) do
      headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
      request("POST", url, headers, JSON.encode!(map), ctx)
    end

    @doc """
    Sends one request on a fresh, pinned connection and reads the whole
    response. Header values may be `ConduitMcp.Client.Secret`s.
    """
    @spec request(String.t(), String.t(), [{String.t(), term()}], iodata() | nil, ctx()) ::
            {:ok, response()} | {:error, reason()}
    def request(method, url, headers, body, ctx) do
      deadline = now_ms() + Map.get(ctx, :timeout, @default_timeout)

      with {:ok, uri} <- parse(url, ctx),
           {:ok, targets} <- targets(url, uri, ctx),
           {:ok, conn} <- connect(targets, uri, ctx, deadline) do
        headers = [{"accept-encoding", "identity"} | Enum.map(headers, &expose/1)]

        try do
          send_and_read(conn, method, path(uri), headers, body, ctx, deadline)
        after
          Mint.HTTP.close(conn)
        end
      end
    end

    defp expose({name, value}),
      do: {name, if(Secret.secret?(value), do: Secret.expose(value), else: value)}

    defp parse(url, ctx) do
      case URL.parse(url, allow_insecure: Map.get(ctx, :allow_insecure, false)) do
        {:ok, %URI{fragment: nil} = uri} -> {:ok, uri}
        {:ok, %URI{}} -> {:error, {:invalid_url, :fragment}}
        {:error, error} -> {:error, {:invalid_url, error.reason}}
      end
    end

    # `https`: the vetted addresses, connected with the hostname for TLS.
    # Plain `http` exists only behind `allow_insecure` and only for a
    # loopback host (`URL.parse/2` enforces both).
    defp targets(url, %URI{scheme: "https"}, ctx) do
      opts =
        [allow_private: Map.get(ctx, :allow_private, [])] ++
          if(ctx[:resolver], do: [resolver: ctx[:resolver]], else: [])

      case URLPolicy.check(url, :public_only, opts) do
        {:ok, %{addresses: addresses}} -> {:ok, addresses}
        {:error, reason} -> {:error, {:url_blocked, reason}}
      end
    end

    defp targets(_url, %URI{scheme: "http", host: host}, _ctx), do: {:ok, [host]}

    defp connect([], _uri, _ctx, _deadline), do: {:error, {:transport_error, :no_address}}

    defp connect([address | rest], uri, ctx, deadline) do
      scheme = String.to_existing_atom(uri.scheme)
      port = uri.port || URI.default_port(uri.scheme)
      timeout = max(deadline - now_ms(), 1)

      opts = [mode: :passive, protocols: [:http1], hostname: uri.host]

      opts =
        if scheme == :https,
          do: opts ++ [transport_opts: Keyword.put(tls_opts(ctx), :timeout, timeout)],
          else: opts ++ [transport_opts: [timeout: timeout]]

      case Mint.HTTP.connect(scheme, address, port, opts) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, reason} ->
          if rest == [] or now_ms() >= deadline,
            do: {:error, {:transport_error, reason}},
            else: connect(rest, uri, ctx, deadline)
      end
    end

    defp tls_opts(ctx) do
      ctx
      |> Map.get(:transport_opts, [])
      |> Keyword.put_new(:verify, :verify_peer)
    end

    defp path(%URI{path: path, query: query}) do
      path = if path in [nil, ""], do: "/", else: path
      if query in [nil, ""], do: path, else: path <> "?" <> query
    end

    defp send_and_read(conn, method, path, headers, body, ctx, deadline) do
      case Mint.HTTP.request(conn, method, path, headers, body) do
        {:ok, conn, ref} ->
          max = Map.get(ctx, :max_bytes, @default_max_bytes)
          read(conn, ref, %{status: nil, headers: [], body: [], size: 0}, max, deadline)

        {:error, _conn, reason} ->
          {:error, {:transport_error, reason}}
      end
    end

    defp read(conn, ref, acc, max, deadline) do
      timeout = deadline - now_ms()

      if timeout <= 0 do
        {:error, :timeout}
      else
        case Mint.HTTP.recv(conn, 0, timeout) do
          {:ok, conn, responses} ->
            case collect(responses, ref, acc, max) do
              {:done, acc} -> finish(acc)
              {:more, acc} -> read(conn, ref, acc, max, deadline)
              {:error, _reason} = error -> error
            end

          {:error, _conn, %Mint.TransportError{reason: :timeout}, _responses} ->
            {:error, :timeout}

          {:error, _conn, reason, _responses} ->
            {:error, {:transport_error, reason}}
        end
      end
    end

    defp collect([], _ref, acc, _max), do: {:more, acc}

    defp collect([{:status, ref, status} | rest], ref, acc, max),
      do: collect(rest, ref, %{acc | status: status}, max)

    defp collect([{:headers, ref, headers} | rest], ref, acc, max) do
      headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
      acc = %{acc | headers: acc.headers ++ headers}

      cond do
        acc.status in 300..399 -> {:error, {:redirect, acc.status}}
        encoded?(acc.headers) -> {:error, {:unsupported_content_encoding, encoding(acc.headers)}}
        true -> collect(rest, ref, acc, max)
      end
    end

    defp collect([{:data, ref, data} | rest], ref, acc, max) do
      size = acc.size + byte_size(data)

      if size > max,
        do: {:error, :message_too_large},
        else: collect(rest, ref, %{acc | body: [acc.body, data], size: size}, max)
    end

    defp collect([{:done, ref} | _rest], ref, acc, _max), do: {:done, acc}

    defp collect([{:error, ref, reason} | _rest], ref, _acc, _max),
      do: {:error, {:transport_error, reason}}

    defp collect([_other | rest], ref, acc, max), do: collect(rest, ref, acc, max)

    defp finish(acc) do
      {:ok, %{status: acc.status, headers: acc.headers, body: IO.iodata_to_binary(acc.body)}}
    end

    defp encoded?(headers) do
      case encoding(headers) do
        nil -> false
        value -> String.downcase(String.trim(value)) not in ["", "identity"]
      end
    end

    defp encoding(headers) do
      case List.keyfind(headers, "content-encoding", 0) do
        {_name, value} -> value
        nil -> nil
      end
    end

    @doc "Decodes a JSON object body, or `:error`."
    @spec json(response()) :: {:ok, map()} | :error
    def json(%{body: body}) do
      case JSON.decode(body) do
        {:ok, %{} = map} -> {:ok, map}
        _other -> :error
      end
    end

    defp now_ms, do: System.monotonic_time(:millisecond)
  end
end
