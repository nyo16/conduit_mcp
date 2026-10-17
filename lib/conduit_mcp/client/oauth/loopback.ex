if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.Loopback do
    @moduledoc """
    Interactive authorization for CLI and desktop apps: a one-shot callback
    server on `127.0.0.1` (RFC 8252 §7.3 loopback redirect). Compiled only
    with `:finch`.

        {:ok, tokens} =
          ConduitMcp.Client.OAuth.Loopback.run(:docs,
            open: fn url -> System.cmd("open", [url]) end,
            challenge: challenge
          )

    `run/2`:

      1. starts Bandit on `127.0.0.1` (port `0` by default: any free port,
         which RFC 8252 lets the authorization server accept for loopback
         redirect URIs; give `:port` if yours needs a fixed one) serving
         exactly one request on `:path`;
      2. builds the authorization URL with redirect URI
         `http://127.0.0.1:<port><path>` (`ConduitMcp.Client.OAuth.authorize_url/2`);
      3. calls the host's `:open` function with the URL - **the library
         never launches a browser itself**: the host decides how (`open`,
         `xdg-open`, printing the URL);
      4. waits (`:timeout`, default 5 minutes) for the browser's redirect,
         answers it with a short page, and stops the server;
      5. completes the flow with `ConduitMcp.Client.OAuth.handle_callback/3`.

    The server binds the loopback address only and answers a single
    callback (OA-11): any later request gets `410 Gone`, and the listener is
    gone right after. The pending authorization never leaves the calling
    process, so `state` is used once by construction.

    `start/1` and `await/2` are the two halves of step 1 and 4, for a host
    that runs the flow itself; `await/2` returns the callback's query
    parameters.
    """

    alias ConduitMcp.Client.OAuth

    @enforce_keys [:server, :ref, :redirect_uri]
    defstruct [:server, :ref, :redirect_uri]

    @type t :: %__MODULE__{server: pid(), ref: reference(), redirect_uri: String.t()}

    @default_timeout :timer.minutes(5)

    defmodule Plug do
      @moduledoc false
      # Answers the first request on the callback path and reports its
      # query parameters to the waiting process; refuses everything else.

      @behaviour Elixir.Plug

      import Elixir.Plug.Conn

      @impl true
      def init(opts), do: opts

      # sobelow_skip ["XSS.SendResp"]
      # `page/1` returns one of two literal pages; nothing from the request
      # (the query only decides which) is ever written into the body.
      @impl true
      def call(%{method: "GET", request_path: path} = conn, %{path: path} = opts) do
        if :atomics.compare_exchange(opts.once, 1, 0, 1) == :ok do
          conn = fetch_query_params(conn)
          send(opts.owner, {opts.ref, :callback, conn.query_params})

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, page(conn.query_params))
        else
          send_resp(conn, 410, "")
        end
      end

      def call(conn, _opts), do: send_resp(conn, 404, "")

      defp page(%{"error" => _}),
        do:
          "<!doctype html><title>Authorization</title><p>Authorization was not granted. You can close this window.</p>"

      defp page(_params),
        do:
          "<!doctype html><title>Authorization</title><p>Authorization complete. You can close this window.</p>"
    end

    @doc """
    Starts the one-shot callback server.

    ## Options

      * `:port` - default `0` (any free port).
      * `:path` - the callback path, default `"/callback"`.
    """
    @spec start(keyword()) :: {:ok, t()} | {:error, term()}
    def start(opts \\ []) do
      path = Keyword.get(opts, :path, "/callback")
      ref = make_ref()
      plug_opts = %{owner: self(), ref: ref, path: path, once: :atomics.new(1, [])}

      case Bandit.start_link(
             plug: {__MODULE__.Plug, plug_opts},
             scheme: :http,
             ip: {127, 0, 0, 1},
             port: Keyword.get(opts, :port, 0),
             startup_log: false
           ) do
        {:ok, server} ->
          # Linked: the server goes when the caller does. `stop/1` ends it
          # with reason `:normal`, which a link does not propagate.
          {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

          {:ok,
           %__MODULE__{server: server, ref: ref, redirect_uri: "http://127.0.0.1:#{port}#{path}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Waits up to `timeout` ms for the callback, then stops the server.
    Returns the callback's query parameters, or `{:error, :timeout}`.
    """
    @spec await(t(), timeout()) :: {:ok, map()} | {:error, :timeout}
    def await(%__MODULE__{ref: ref} = loopback, timeout \\ @default_timeout) do
      receive do
        {^ref, :callback, params} ->
          stop(loopback)
          {:ok, params}
      after
        timeout ->
          stop(loopback)
          {:error, :timeout}
      end
    end

    @doc "Stops the callback server (idempotent)."
    @spec stop(t()) :: :ok
    def stop(%__MODULE__{server: server}) do
      if Process.alive?(server), do: ThousandIsland.stop(server, 1_000)
      :ok
    catch
      :exit, _reason -> :ok
    end

    @doc """
    Runs a whole interactive authorization for `client_or_config` (see the
    moduledoc) and returns the stored tokens.

    ## Options

      * `:open` (required) - a one-arity function given the authorization
        URL.
      * `:port`, `:path` - see `start/1`.
      * `:timeout` - how long to wait for the user, default 5 minutes.
      * `:challenge`, `:scopes`, `:principal` - passed to
        `ConduitMcp.Client.OAuth.authorize_url/2`.
    """
    @spec run(OAuth.client_or_config(), keyword()) ::
            {:ok, OAuth.Tokens.t()} | {:error, term()}
    def run(client_or_config, opts) do
      open = Keyword.fetch!(opts, :open)

      if not is_function(open, 1),
        do: raise(ArgumentError, ":open must be a one-arity function")

      with {:ok, loopback} <- start(opts) do
        try do
          authorize_opts =
            opts
            |> Keyword.take([:challenge, :scopes, :principal])
            |> Keyword.put(:redirect_uri, loopback.redirect_uri)

          with {:ok, url, pending} <- OAuth.authorize_url(client_or_config, authorize_opts),
               _ <- open.(url),
               {:ok, params} <- await(loopback, Keyword.get(opts, :timeout, @default_timeout)) do
            OAuth.handle_callback(pending, params, callback_opts(client_or_config, opts))
          end
        after
          stop(loopback)
        end
      end
    end

    defp callback_opts(%OAuth.Config{} = config, opts),
      do: [config: config] ++ Keyword.take(opts, [:principal])

    defp callback_opts(config, opts) when is_list(config),
      do: [config: config] ++ Keyword.take(opts, [:principal])

    defp callback_opts(client, opts), do: [client: client] ++ Keyword.take(opts, [:principal])
  end
end
