defmodule ConduitMcp.Client.OAuth.StoreAndConfigTest do
  use ExUnit.Case, async: true

  doctest ConduitMcp.Client.OAuth.CIMD

  alias ConduitMcp.Client
  alias ConduitMcp.Client.OAuth.{CIMD, Config, Tokens, TokenStore}
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.StreamableHTTP

  describe "TokenStore.ETS" do
    setup do
      store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
      start_supervised!(store)
      %{store: store}
    end

    test "tokens are keyed by principal, issuer and resource; clients by issuer", %{store: store} do
      tokens = Tokens.new(access_token: "at", refresh_token: "rt")
      key = {"alice", "https://as.example", "https://mcp.example/a"}

      assert :ok = TokenStore.put_tokens(store, key, tokens)
      assert {:ok, ^tokens} = TokenStore.fetch_tokens(store, key)

      assert :error =
               TokenStore.fetch_tokens(
                 store,
                 {"bob", "https://as.example", "https://mcp.example/a"}
               )

      assert :error =
               TokenStore.fetch_tokens(
                 store,
                 {"alice", "https://as.example", "https://mcp.example/b"}
               )

      assert :error =
               TokenStore.fetch_tokens(
                 store,
                 {"alice", "https://other.example", "https://mcp.example/a"}
               )

      assert :ok = TokenStore.put_client(store, "https://as.example", %{"client_id" => "c"})
      assert {:ok, %{"client_id" => "c"}} = TokenStore.fetch_client(store, "https://as.example")
      assert :error = TokenStore.fetch_client(store, "https://other.example")

      assert :ok = TokenStore.delete(store, key, :tokens)
      assert :error = TokenStore.fetch_tokens(store, key)
      assert :ok = TokenStore.delete(store, "https://as.example", :client)
      assert :error = TokenStore.fetch_client(store, "https://as.example")
    end

    test "the table is :protected: readable anywhere, written only by its owner (OA-9)", %{
      store: store
    } do
      {_module, opts} = store
      {:ok, owner, tid} = Registry.lookup({:token_store, opts[:name]})

      assert :ets.info(tid, :protection) == :protected
      assert :ets.info(tid, :owner) == owner
      assert_raise ArgumentError, fn -> :ets.insert(tid, {{:tokens, :forged}, :x}) end
    end

    test "the crash report never shows a write's tokens", %{store: store} do
      {_module, opts} = store
      {:ok, owner, _tid} = Registry.lookup({:token_store, opts[:name]})

      status = :sys.get_status(owner)
      refute inspect(status) =~ "rt"

      formatted =
        TokenStore.ETS.format_status(%{state: %{}, message: {:put, :k, :secret}, log: [:x]})

      assert formatted.message == :redacted
      assert formatted.log == []
    end

    test "a stopped store reads as empty and refuses writes" do
      store = {TokenStore.ETS, name: {__MODULE__, :never_started}}
      assert :error = TokenStore.fetch_tokens(store, {nil, "i", "r"})

      assert {:error, :store_unavailable} =
               TokenStore.put_tokens(store, {nil, "i", "r"}, Tokens.new(access_token: "a"))
    end

    test "transaction/3 defaults to a :global lock and returns the function's result", %{
      store: store
    } do
      assert :result = TokenStore.transaction(store, {nil, "i", "r"}, fn -> :result end)
    end
  end

  describe "Config" do
    test "secrets are wrapped and never inspected" do
      config =
        Config.new!(
          server_url: "https://mcp.example.com",
          pre_registered: %{"https://as.example" => [client_id: "c", client_secret: "hunter2"]}
        )

      assert %{client_id: "c", auth_method: :client_secret_basic, secret: %Secret{}} =
               config.pre_registered["https://as.example"]

      refute inspect(config) =~ "hunter2"
    end

    test "invalid options are refused, naming the option" do
      for {opts, message} <- [
            {[redirect_uri: "http://example.com/cb"], ~r/redirect_uri/},
            {[client_metadata_url: "https://app.example.com/"], ~r/client_metadata_url/},
            {[client_metadata_url: "http://app.example.com/c.json"], ~r/client_metadata_url/},
            {[allow_private: ["nope"]], ~r/allow_private/},
            {[pre_registered: %{"https://as" => [client_secret: "x"]}], ~r/client_id/},
            {[store: {String, []}], ~r/TokenStore/},
            {[max_step_up_attempts: -1], ~r/max_step_up_attempts/}
          ] do
        assert {:error, error} = Config.new([server_url: "https://mcp.example.com"] ++ opts)
        assert error =~ message
      end
    end

    test "the transport builds it for its URL and starts the default store" do
      name = {__MODULE__, make_ref()}

      spec =
        Client.child_spec(
          name: name,
          transport:
            {StreamableHTTP,
             url: "https://mcp.example.com/mcp",
             auth: {:oauth, redirect_uri: "http://127.0.0.1:1/cb"}}
        )

      {Client, :start_link, [opts]} = spec.start
      config = ConduitMcp.Client.Config.new!(opts)
      {StreamableHTTP, transport_opts} = config.transport

      assert {:oauth, %Config{server_url: "https://mcp.example.com/mcp"} = oauth} =
               transport_opts[:auth]

      assert oauth.store == nil

      assert [
               _finch,
               %{id: :oauth_token_store, start: {TokenStore.ETS, :start_link, [store_opts]}}
             ] =
               StreamableHTTP.child_specs(transport_opts, name)

      assert store_opts == [name: {:client, name}]
    end

    test "bad OAuth options, or OAuth over plain http to a remote host, fail at child_spec" do
      assert_raise ArgumentError, ~r/:auth.*redirect_uri/s, fn ->
        Client.child_spec(
          name: :bad_oauth,
          transport:
            {StreamableHTTP,
             url: "https://mcp.example.com/",
             auth: {:oauth, redirect_uri: "http://evil.example/cb"}}
        )
      end

      assert_raise ArgumentError, ~r/plain http/, fn ->
        Client.child_spec(
          name: :bad_oauth,
          transport: {StreamableHTTP, url: "http://mcp.example.com/", auth: {:oauth, []}}
        )
      end
    end
  end

  describe "CIMD.document/1" do
    test "declares the code flow for a public client" do
      document =
        CIMD.document(
          client_id: "https://app.example.com/oauth/client.json",
          client_name: "Agent",
          redirect_uris: ["http://127.0.0.1:33418/callback"],
          application_type: :native,
          logo_uri: "https://app.example.com/logo.png"
        )

      assert document == %{
               "client_id" => "https://app.example.com/oauth/client.json",
               "client_name" => "Agent",
               "redirect_uris" => ["http://127.0.0.1:33418/callback"],
               "grant_types" => ["authorization_code", "refresh_token"],
               "response_types" => ["code"],
               "token_endpoint_auth_method" => "none",
               "application_type" => "native",
               "logo_uri" => "https://app.example.com/logo.png"
             }
    end

    test "refuses a client id that is not an https URL with a path" do
      assert_raise ArgumentError, fn ->
        CIMD.document(client_id: "https://app.example.com", client_name: "x", redirect_uris: [])
      end
    end
  end
end
