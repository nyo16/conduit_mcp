defmodule ConduitMcp.Client.TokenLeakTest do
  # B1: a credential holding a byte an HTTP header cannot carry (a trailing
  # newline from `File.read!/1`, a control byte from an authorization
  # server) must never reach Mint, which would echo the whole header value
  # in its error. The token is refused with a typed error naming no value,
  # and every HTTP-layer error that does carry a header value is stripped
  # of it, so nothing can surface in a `ConduitMcp.Client.Error`, its
  # message, the logs or an LLM adapter's tool result.
  use ExUnit.Case, async: true

  @moduletag :integration

  import ExUnit.CaptureLog

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Adapters.{Anthropic, Gemini, OpenAI}
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.HTTP
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.TokenStore
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.HTTPDslServer
  alias ConduitMcp.Test.Client.HTTPServers
  alias ConduitMcp.Test.Client.OAuthFake

  @token "LEAK-c0nduit-b1d00d42"

  # Everything the error can be rendered into.
  defp renderings(%Error{} = error) do
    [
      inspect(error),
      inspect(error, printable_limit: :infinity, limit: :infinity),
      Exception.message(error),
      inspect(Anthropic.tool_result("toolu_1", error)),
      inspect(Gemini.function_response("echo", error)),
      inspect(OpenAI.tool_output("call_1", error, api: :chat)),
      inspect(OpenAI.tool_output("call_1", error, api: :responses))
    ]
  end

  defp refute_leak(text) when is_binary(text), do: refute(text =~ @token)

  describe "an :auth function returning a token with a newline" do
    setup do
      url = HTTPServers.serve_mcp(HTTPDslServer)
      {:ok, bad?} = Agent.start_link(fn -> false end)

      auth = fn _request ->
        if Agent.get(bad?, & &1), do: {:ok, @token <> "\n"}, else: {:ok, "good-token"}
      end

      name = {__MODULE__, make_ref()}

      start_supervised!(
        {Client,
         name: name,
         transport: {StreamableHTTP, url: url, auth: auth},
         max_reconnects: 0,
         backoff: fn _attempt -> 0 end}
      )

      assert :ok = Client.await_ready(name, 5_000)
      %{name: name, bad?: bad?}
    end

    test "fails the request with kind :auth and no token byte anywhere", ctx do
      Agent.update(ctx.bad?, fn _ -> true end)

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %Error{kind: :auth, reason: :invalid_token} = error} =
                   Client.call_tool(ctx.name, "echo", %{"message" => "hi"})

          Enum.each(renderings(error), &refute_leak/1)
        end)

      refute_leak(log)
    end
  end

  describe "StreamableHTTP.bearer/1" do
    test "accepts visible ASCII only, and names no value when it refuses" do
      assert {:ok, %Secret{} = header} = StreamableHTTP.bearer(@token)
      assert Secret.expose(header) == "Bearer " <> @token
      assert {:ok, _header} = StreamableHTTP.bearer(Secret.new(@token))

      for bad <- [
            @token <> "\n",
            @token <> "\r\n",
            "\t" <> @token,
            @token <> " x",
            @token <> <<1>>,
            @token <> <<0x7F>>,
            @token <> "é",
            ""
          ] do
        assert {:error, %Error{kind: :auth, reason: :invalid_token} = error} =
                 StreamableHTTP.bearer(bad)

        assert {:error, ^error} = StreamableHTTP.bearer(Secret.new(bad))
        Enum.each(renderings(error), &refute_leak/1)
      end
    end

    test "a static {:bearer, token} with a control byte is refused at configuration" do
      for bad <- [@token <> <<1>>, @token <> <<0x7F>>, @token <> " x", @token <> "é"] do
        assert {:error, message} =
                 StreamableHTTP.validate_options(url: "https://h.example/", auth: {:bearer, bad})

        assert message =~ ":auth"
        refute_leak(message)
      end
    end

    test "a static header value Mint would refuse is refused at configuration" do
      for bad <- [@token <> <<1>>, @token <> <<0x7F>>, @token <> "é"] do
        assert {:error, message} =
                 StreamableHTTP.validate_options(
                   url: "https://h.example/",
                   headers: [{"x-api-key", Secret.new(bad)}]
                 )

        assert message =~ "x-api-key"
        refute_leak(message)
      end

      assert {:ok, _opts} =
               StreamableHTTP.validate_options(
                 url: "https://h.example/",
                 headers: [{"x-note", "a value\twith space and tab"}]
               )
    end
  end

  describe "HTTP-layer errors carry no header value" do
    test "Client.HTTP: Mint's invalid_header_value keeps the name only" do
      url = HTTPServers.serve_mcp(HTTPDslServer)
      finch = :"#{__MODULE__}.Finch#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      assert {:error, {:transport_error, {:invalid_header_value, "x-api-key"}} = reason} =
               HTTP.open(%{
                 method: :post,
                 url: url,
                 headers: [{"x-api-key", Secret.new(@token <> <<1>>)}],
                 body: "{}",
                 finch: finch,
                 deadline: System.monotonic_time(:millisecond) + 5_000
               })

      refute_leak(inspect(reason, printable_limit: :infinity, limit: :infinity))
      Enum.each(renderings(Error.new(:transport, reason)), &refute_leak/1)
    end

    test "OAuth.HTTP: Mint's invalid_header_value keeps the name only" do
      base = HTTPServers.serve_mcp(HTTPDslServer)

      assert {:error, {:transport_error, {:invalid_header_value, "authorization"}} = reason} =
               OAuth.HTTP.request(
                 "GET",
                 base <> "meta",
                 [{"authorization", Secret.new("Basic " <> @token <> "\n")}],
                 nil,
                 %{allow_insecure: true}
               )

      refute_leak(inspect(reason, printable_limit: :infinity, limit: :infinity))
    end
  end

  describe "an authorization server issuing a token with a control byte" do
    setup do
      fake = OAuthFake.start()

      OAuthFake.serve_prm(
        fake,
        "/.well-known/oauth-protected-resource/mcp",
        fake.url <> "/mcp",
        scopes_supported: ["read"]
      )

      OAuthFake.serve_as(fake)

      OAuthFake.route(
        fake,
        "POST",
        "/token",
        {200, %{"access_token" => @token <> <<1>>, "token_type" => "Bearer"}}
      )

      store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
      start_supervised!(store)

      config =
        OAuth.Config.new!(
          server_url: fake.url <> "/mcp",
          grant: :client_credentials,
          client_id: "svc",
          client_secret: "s3cret",
          scopes: ["read"],
          allow_insecure_oauth: true,
          store: store
        )

      %{config: config}
    end

    test "the token response is refused as invalid, without the token", %{config: config} do
      log =
        capture_log([level: :debug], fn ->
          assert {:error,
                  %OAuth.Error{
                    reason: :token_request_failed,
                    data: %{reason: :invalid_token_response}
                  } = error} = OAuth.token_for(config, nil)

          refute_leak(inspect(error, printable_limit: :infinity, limit: :infinity))
          refute_leak(Exception.message(error))
        end)

      refute_leak(log)
    end
  end
end
