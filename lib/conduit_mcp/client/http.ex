if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.HTTP do
    @moduledoc false

    # The client's HTTP layer, on Finch (compiled only when `:finch` is
    # available; `ConduitMcp.OptionalDeps.finch!/0` returns this module).
    # Everything here runs in the process that makes the request - an
    # Exchange or Listener of `ConduitMcp.Client.Transport.StreamableHTTP`,
    # never the connection, except the bounded DELETE of `request/2` - and
    # blocks only that process.
    #
    # Guarantees (CS §7):
    #
    #   * HT-1: `accept-encoding: identity` is always sent and a body is
    #     never decompressed: a response with any other `content-encoding`
    #     is refused before its body is read (`{:unsupported_content_encoding,
    #     value}`), so a gzip bomb costs nothing.
    #   * HT-2: `read_body/2` stops at `max` bytes (`:message_too_large`)
    #     and cancels the request; event streams are capped by
    #     `ConduitMcp.Client.SSE`'s limits in the caller.
    #   * HT-3: two clocks. `deadline` is absolute (monotonic ms) and bounds
    #     the whole exchange - status, headers and every byte - so a server
    #     dripping one byte at a time cannot extend it; `idle_timeout`
    #     restarts on every chunk (keep-alive comments included) and bounds
    #     silence on long-lived streams. Finch's own per-chunk
    #     `:receive_timeout` is `:infinity`: these watchdogs replace it.
    #   * HT-4: redirects are refused unless `redirect: :same_origin`, which
    #     follows 307/308 to the same scheme, host and port only (at most 5),
    #     re-sending the same method, body and headers - credentials
    #     included, since the origin is unchanged.
    #   * Cancel: `cancel/1` calls `Finch.cancel_async_request/1`, which on
    #     HTTP/1 stops the worker owning the socket, so the socket closes
    #     and the server sees the disconnect (modern-era cancellation); then
    #     drops any message of the request already in the mailbox.
    #
    # The pool: a user-started Finch (`finch:` option), or the one
    # `child_spec/3` builds, started under the client's supervisor.

    alias ConduitMcp.Client.Secret

    @max_redirects 5

    defmodule Response do
      @moduledoc false
      # An open response: status and headers received, body pending.
      defstruct [:ref, :status, :headers, :url, :deadline, :idle_timeout, :idle_deadline]

      @type t :: %__MODULE__{
              ref: term(),
              status: non_neg_integer(),
              headers: [{String.t(), String.t()}],
              url: String.t(),
              deadline: integer() | :infinity,
              idle_timeout: pos_integer() | :infinity,
              idle_deadline: integer() | :infinity
            }
    end

    @type request :: %{
            required(:method) => :get | :post | :delete,
            required(:url) => String.t(),
            required(:headers) => [{String.t(), String.t() | Secret.t()}],
            required(:finch) => atom(),
            optional(:body) => iodata() | nil,
            optional(:deadline) => integer() | :infinity,
            optional(:idle_timeout) => pos_integer() | :infinity,
            optional(:redirect) => false | :same_origin
          }

    # --- the pool ----------------------------------------------------------

    @doc """
    The name of the Finch pool the library starts for client `key`. Finch
    names are atoms; this one is derived from a hash of the key, so a client
    name is never turned into an atom itself.
    """
    @spec pool_name(term()) :: atom()
    def pool_name(key) do
      hash =
        :sha256
        |> :crypto.hash(:erlang.term_to_binary(key))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 24)

      # The hash is hex: a bounded alphabet, one atom per distinct client.
      String.to_atom("Elixir.ConduitMcp.Client.Finch." <> hash)
    end

    @doc """
    The child spec of a library-started pool named `name` for `url`: HTTP/1
    only (one stream per connection, so a cancel closes exactly one socket),
    `size` connections, and for `https` TLS peer verification with the
    operating system's CA store (Mint's default) unless `insecure` is set.
    """
    @spec child_spec(atom(), String.t(), keyword()) :: Supervisor.child_spec()
    def child_spec(name, url, opts) do
      conn_opts =
        case URI.parse(url) do
          %URI{scheme: "https"} -> [transport_opts: tls_opts(opts)]
          _plain -> []
        end

      pool = [size: Keyword.fetch!(opts, :size), count: 1, protocols: [:http1]]
      pool = if conn_opts == [], do: pool, else: Keyword.put(pool, :conn_opts, conn_opts)

      Supervisor.child_spec({Finch, name: name, pools: %{default: pool}}, id: :finch)
    end

    defp tls_opts(opts) do
      user = Keyword.get(opts, :transport_opts, [])

      if Keyword.get(opts, :insecure, false),
        do: Keyword.merge(user, verify: :verify_none),
        else: Keyword.put_new(user, :verify, :verify_peer)
    end

    # --- requests ----------------------------------------------------------

    @doc """
    Sends `request` and waits for its status and headers. Returns the open
    response (read the body with `next/1` or `read_body/2`), or an error:
    `{:redirect_refused, status}`, `{:unsupported_content_encoding, value}`,
    `:timeout`, `:idle_timeout` or `{:transport_error, reason}`.
    """
    @spec open(request()) :: {:ok, Response.t()} | {:error, term()}
    def open(request), do: open(request, @max_redirects)

    defp open(request, redirects_left) do
      deadline = Map.get(request, :deadline, :infinity)
      idle_timeout = Map.get(request, :idle_timeout, :infinity)

      headers =
        [{"accept-encoding", "identity"} | Enum.map(request.headers, &expose/1)]

      finch_request =
        Finch.build(request.method, request.url, headers, Map.get(request, :body))

      ref = Finch.async_request(finch_request, request.finch, receive_timeout: :infinity)

      response = %Response{
        ref: ref,
        url: request.url,
        deadline: deadline,
        idle_timeout: idle_timeout,
        idle_deadline: idle_deadline(idle_timeout)
      }

      with {:ok, response} <- await_head(response) do
        check_head(response, request, redirects_left)
      end
    rescue
      # `Finch.build/5` raises on a URL it cannot parse; `async_request/3`
      # on a pool that is not running.
      error in [ArgumentError, Finch.Error] -> {:error, {:transport_error, error}}
    end

    defp expose({name, value}),
      do: {name, if(Secret.secret?(value), do: Secret.expose(value), else: value)}

    defp await_head(%Response{status: status, headers: headers} = response)
         when status != nil and headers != nil,
         do: {:ok, response}

    defp await_head(%Response{ref: ref} = response) do
      receive do
        {^ref, {:status, status}} ->
          await_head(touch(%{response | status: status}))

        {^ref, {:headers, headers}} ->
          await_head(touch(%{response | headers: downcase(headers)}))

        {^ref, {:data, _data}} ->
          # A body before headers cannot happen; treat it as headerless.
          await_head(%{response | headers: response.headers || []})

        {^ref, :done} ->
          {:ok, %{response | headers: response.headers || []}}

        {^ref, {:error, error}} ->
          {:error, {:transport_error, error}}
      after
        wait_ms(response) -> timed_out(response)
      end
    end

    defp check_head(response, request, redirects_left) do
      cond do
        response.status in 300..399 ->
          redirect(response, request, redirects_left)

        encoded?(response) ->
          refuse(response, {:unsupported_content_encoding, encoding(response)})

        true ->
          {:ok, response}
      end
    end

    # HT-4: only 307/308 (which keep the method and body) to the same
    # origin, and only when asked for.
    defp redirect(response, request, redirects_left) do
      location = header(response, "location")
      target = location && resolve(request.url, location)

      if Map.get(request, :redirect, false) == :same_origin and response.status in [307, 308] and
           target != nil and same_origin?(request.url, target) and redirects_left > 0 do
        cancel(response)
        open(%{request | url: target}, redirects_left - 1)
      else
        refuse(response, {:redirect_refused, response.status})
      end
    end

    defp resolve(base, location) do
      base |> URI.merge(location) |> URI.to_string()
    rescue
      ArgumentError -> nil
    end

    defp refuse(response, reason) do
      cancel(response)
      {:error, reason}
    end

    defp encoded?(response) do
      case encoding(response) do
        nil -> false
        value -> String.downcase(String.trim(value)) not in ["", "identity"]
      end
    end

    defp encoding(response), do: header(response, "content-encoding")

    @doc "The next body chunk: `{:data, binary, response}`, `:done`, or an error (the request is cancelled)."
    @spec next(Response.t()) :: {:data, binary(), Response.t()} | :done | {:error, term()}
    def next(%Response{ref: ref} = response) do
      receive do
        {^ref, {:data, data}} -> {:data, data, touch(response)}
        {^ref, :done} -> :done
        {^ref, {:error, error}} -> {:error, {:transport_error, error}}
        {^ref, {:trailers, _trailers}} -> next(response)
      after
        wait_ms(response) -> timed_out(response)
      end
    end

    @doc """
    Reads the whole body, at most `max` bytes. A longer body cancels the
    request and returns `{:error, :message_too_large}`.
    """
    @spec read_body(Response.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
    def read_body(response, max), do: read_body(response, max, 0, [])

    defp read_body(response, max, size, acc) do
      case next(response) do
        {:data, data, response} ->
          size = size + byte_size(data)

          if size > max,
            do: refuse(response, :message_too_large),
            else: read_body(response, max, size, [acc, data])

        :done ->
          {:ok, IO.iodata_to_binary(acc)}

        {:error, _reason} = error ->
          error
      end
    end

    @doc """
    Cancels the request (closing its socket) and drops its messages already
    in the mailbox.
    """
    @spec cancel(Response.t()) :: :ok
    def cancel(%Response{ref: ref}) do
      :ok = Finch.cancel_async_request(ref)
      flush(ref)
    end

    defp flush(ref) do
      receive do
        {^ref, _message} -> flush(ref)
      after
        0 -> :ok
      end
    end

    @doc """
    A whole request bounded by `timeout` ms in total: `{:ok, status, body}`
    (body capped at 64 KiB) or `{:error, reason}`.
    """
    @spec request(request(), pos_integer()) ::
            {:ok, non_neg_integer(), binary()} | {:error, term()}
    def request(request, timeout) do
      request = Map.put(request, :deadline, now_ms() + timeout)

      with {:ok, response} <- open(request),
           {:ok, body} <- read_body(response, 65_536) do
        {:ok, response.status, body}
      end
    end

    # --- headers and URLs ----------------------------------------------------

    @doc "The first value of response header `name` (lowercase), or `nil`."
    @spec header(Response.t(), String.t()) :: String.t() | nil
    def header(%Response{headers: headers}, name) do
      case List.keyfind(headers || [], name, 0) do
        {_name, value} -> value
        nil -> nil
      end
    end

    @doc "Every value of response header `name` (lowercase)."
    @spec headers(Response.t(), String.t()) :: [String.t()]
    def headers(%Response{headers: headers}, name),
      do: for({^name, value} <- headers || [], do: value)

    @doc "The media type of the response (`\"application/json\"`), lowercase, or `nil`."
    @spec media_type(Response.t()) :: String.t() | nil
    def media_type(response) do
      case header(response, "content-type") do
        nil ->
          nil

        value ->
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
      end
    end

    @doc "Whether two absolute URLs have the same scheme, host and port."
    @spec same_origin?(String.t(), String.t()) :: boolean()
    def same_origin?(a, b), do: origin(a) == origin(b) and origin(a) != nil

    @doc "`{scheme, host, port}` of an absolute `http(s)` URL, lowercased, or `nil`."
    @spec origin(String.t()) :: {String.t(), String.t(), :inet.port_number()} | nil
    def origin(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, port: port}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          {scheme, String.downcase(host), port}

        _other ->
          nil
      end
    end

    defp downcase(headers), do: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    # --- clocks --------------------------------------------------------------

    defp touch(%Response{idle_timeout: idle} = response),
      do: %{response | idle_deadline: idle_deadline(idle)}

    defp idle_deadline(:infinity), do: :infinity
    defp idle_deadline(ms), do: now_ms() + ms

    defp wait_ms(%Response{deadline: deadline, idle_deadline: idle}) do
      case min_deadline(deadline, idle) do
        :infinity -> :infinity
        at -> max(at - now_ms(), 0)
      end
    end

    defp min_deadline(:infinity, b), do: b
    defp min_deadline(a, :infinity), do: a
    defp min_deadline(a, b), do: min(a, b)

    defp timed_out(%Response{deadline: deadline} = response) do
      cancel(response)

      if deadline != :infinity and deadline <= now_ms(),
        do: {:error, :timeout},
        else: {:error, :idle_timeout}
    end

    defp now_ms, do: System.monotonic_time(:millisecond)
  end
end
