defmodule ConduitMcp.HandlerMRTRTest do
  # async: false — mutates the global :mrtr_keys application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Handler
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.McpSchema

  @version "2026-07-28"
  @elicitation %{"elicitation" => %{}}
  @approve %{"approval" => %{"action" => "accept", "content" => %{"ok" => true}}}

  defmodule DeployServer do
    use ConduitMcp.Server

    tool "deploy", "Deploys after an approval" do
      param(:target, :string, "Deploy target", required: true)

      handle(fn conn, params ->
        case conn.assigns[:mcp_input] do
          nil ->
            {:input_required,
             %{
               "approval" =>
                 ConduitMcp.MRTR.elicit("Approve deploy?", %{
                   "type" => "object",
                   "properties" => %{"ok" => %{"type" => "boolean"}}
                 })
             }, %{step: :awaiting_approval, target: params["target"]}}

          %{
            state: %{"step" => "awaiting_approval", "target" => target},
            responses: %{"approval" => %{"action" => "accept"}}
          } ->
            text("deployed " <> target)

          %{} ->
            text("declined")
        end
      end)
    end

    tool "twice", "Asks for roots twice" do
      handle(fn conn, _params ->
        case conn.assigns[:mcp_input] do
          nil -> {:input_required, %{"r1" => %{"method" => "roots/list"}}, 1}
          %{state: 1} -> {:input_required, %{"r2" => %{"method" => "roots/list"}}, 2}
          %{state: 2, responses: responses} -> text("done #{map_size(responses)}")
        end
      end)
    end

    tool "url", "Needs a URL-mode elicitation" do
      handle(fn _conn, _params ->
        {:input_required,
         %{
           "login" => %{
             "method" => "elicitation/create",
             "params" => %{
               "mode" => "url",
               "message" => "Sign in",
               "url" => "https://example.com/login",
               "elicitationId" => "e1"
             }
           }
         }, nil}
      end)
    end

    tool "pid_state", "Returns a state that cannot be sealed" do
      handle(fn _conn, _params ->
        {:input_required, %{"r" => %{"method" => "roots/list"}}, self()}
      end)
    end

    tool "bogus", "Returns a malformed input request" do
      handle(fn _conn, _params -> {:input_required, %{"x" => %{"method" => "ping"}}, nil} end)
    end

    resource "doc://secret" do
      description("Needs a confirmation")

      read(fn conn, _params, _opts ->
        case conn.assigns[:mcp_input] do
          nil ->
            {:input_required,
             %{
               "confirm" =>
                 ConduitMcp.MRTR.elicit("Reveal?", %{"type" => "object", "properties" => %{}})
             }, "doc"}

          %{state: "doc"} ->
            {:ok, %{"contents" => [%{"uri" => "doc://secret", "text" => "revealed"}]}}
        end
      end)
    end

    prompt "confirm", "Asks before rendering" do
      get(fn conn, _args ->
        case conn.assigns[:mcp_input] do
          nil ->
            {:input_required,
             %{
               "confirm" =>
                 ConduitMcp.MRTR.elicit("Render?", %{"type" => "object", "properties" => %{}})
             }, %{"n" => 1}}

          %{state: %{"n" => 1}} ->
            [user("rendered")]
        end
      end)
    end
  end

  setup do
    previous = Application.fetch_env(:conduit_mcp, :mrtr_keys)
    Application.put_env(:conduit_mcp, :mrtr_keys, [{"k1", :binary.copy(<<7>>, 32)}])

    on_exit(fn ->
      case previous do
        {:ok, keys} -> Application.put_env(:conduit_mcp, :mrtr_keys, keys)
        :error -> Application.delete_env(:conduit_mcp, :mrtr_keys)
      end
    end)
  end

  defp modern(method, params, capabilities \\ @elicitation) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => capabilities
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp retry(request, request_state, responses) do
    update_in(
      request["params"],
      &Map.merge(&1, %{"requestState" => request_state, "inputResponses" => responses})
    )
  end

  # Same "deploy" tool behind a different module: another endpoint in the node.
  defmodule OtherDeployServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    defdelegate handle_list_tools(conn), to: DeployServer

    @impl true
    defdelegate handle_call_tool(conn, name, params), to: DeployServer
  end

  defp dispatch(request, conn \\ conn(:post, "/", "")) do
    assert {:reply, response} = Handler.dispatch(request, DeployServer, conn)
    response
  end

  defp deploy(target \\ "prod"),
    do: modern("tools/call", %{"name" => "deploy", "arguments" => %{"target" => target}})

  describe "tools/call" do
    test "round 1 answers InputRequiredResult; round 2 completes from mcp_input" do
      round1 = dispatch(deploy())
      result = round1["result"]

      assert :ok == McpSchema.validate(@version, "InputRequiredResult", result)
      assert result["resultType"] == "input_required"
      assert %{"approval" => %{"method" => "elicitation/create"}} = result["inputRequests"]
      assert is_binary(result["requestState"])
      refute Map.has_key?(result, "ttlMs")
      refute Map.has_key?(result, "cacheScope")
      assert ConduitMcp.Protocol.Modern.http_status(round1) == 200

      round2 = dispatch(retry(deploy(), result["requestState"], @approve))

      assert %{
               "resultType" => "complete",
               "content" => [%{"type" => "text", "text" => "deployed prod"}]
             } = round2["result"]
    end

    test "a callback may ask again; each round is reported with its number" do
      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :mrtr, :input_required]])

      roots = %{"roots" => %{}}
      request = modern("tools/call", %{"name" => "twice"}, roots)

      %{"result" => %{"requestState" => state1}} = dispatch(request)

      assert_receive {[:conduit_mcp, :mrtr, :input_required], ^ref, %{count: 1},
                      %{method: "tools/call", server_module: DeployServer, round: 1} = metadata}

      assert Map.keys(metadata) |> Enum.sort() == [:method, :round, :server_module]

      %{"result" => %{"requestState" => state2, "inputRequests" => %{"r2" => _}}} =
        dispatch(retry(request, state1, %{"r1" => %{"roots" => []}}))

      assert_receive {[:conduit_mcp, :mrtr, :input_required], ^ref, %{count: 1}, %{round: 2}}

      assert %{"result" => %{"content" => [%{"text" => "done 1"}]}} =
               dispatch(retry(request, state2, %{"r2" => %{"roots" => []}}))

      refute_received {[:conduit_mcp, :mrtr, :input_required], ^ref, _, _}
    end

    test "every requestState failure is the same flat -32602" do
      %{"result" => %{"requestState" => token}} =
        dispatch(deploy(), ConduitMcp.Principal.put(conn(:post, "/", ""), %{id: "alice"}))

      alice = ConduitMcp.Principal.put(conn(:post, "/", ""), %{id: "alice"})
      bob = ConduitMcp.Principal.put(conn(:post, "/", ""), %{id: "bob"})
      [kid, body] = String.split(token, ".")
      <<first, rest::binary>> = body
      flipped = kid <> "." <> <<if(first == ?A, do: ?B, else: ?A), rest::binary>>

      errors =
        [
          dispatch(retry(deploy(), flipped, @approve), alice),
          dispatch(retry(deploy(), token, @approve), bob),
          dispatch(retry(deploy("staging"), token, @approve), alice),
          dispatch(retry(deploy(), "nope", @approve), alice),
          dispatch(retry(deploy(), 42, @approve), alice)
        ]

      expected = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"code" => -32_602, "message" => "Invalid requestState"}
      }

      assert Enum.uniq(errors) == [expected]

      # The genuine token still opens for its principal.
      assert %{"result" => %{"resultType" => "complete"}} =
               dispatch(retry(deploy(), token, @approve), alice)
    end

    test "requestState is never logged" do
      %{"result" => %{"requestState" => token}} = dispatch(deploy())
      Logger.put_process_level(self(), :debug)

      log =
        capture_log([level: :debug], fn ->
          dispatch(retry(deploy(), token <> "x", @approve))
          dispatch(retry(deploy(), token, @approve))
        end)

      refute log =~ token
    end

    test "non-object inputResponses is -32602" do
      %{"result" => %{"requestState" => token}} = dispatch(deploy())

      assert %{"error" => %{"code" => -32_602, "message" => "inputResponses must be an object"}} =
               dispatch(retry(deploy(), token, ["accept"]))
    end

    test "a client without elicitation gets -32021 with requiredCapabilities and HTTP 400" do
      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :mrtr, :input_required]])

      response =
        dispatch(
          modern("tools/call", %{"name" => "deploy", "arguments" => %{"target" => "p"}}, %{})
        )

      assert %{
               "error" => %{
                 "code" => -32_021,
                 "data" => %{"requiredCapabilities" => %{"elicitation" => %{"form" => %{}}}}
               }
             } = response

      assert :ok == McpSchema.validate(@version, "MissingRequiredClientCapabilityError", response)
      assert ConduitMcp.Protocol.Modern.http_status(response) == 400
      refute_received {[:conduit_mcp, :mrtr, :input_required], ^ref, _, _}
    end

    test "URL-mode elicitation needs elicitation.url" do
      form_only = modern("tools/call", %{"name" => "url"}, %{"elicitation" => %{"form" => %{}}})

      assert %{
               "error" => %{
                 "code" => -32_021,
                 "data" => %{"requiredCapabilities" => %{"elicitation" => %{"url" => %{}}}}
               }
             } = dispatch(form_only)

      with_url = modern("tools/call", %{"name" => "url"}, %{"elicitation" => %{"url" => %{}}})
      assert %{"result" => %{"resultType" => "input_required"}} = dispatch(with_url)
    end

    test "without :mrtr_keys the request fails with -32603 and an operator log line" do
      Application.delete_env(:conduit_mcp, :mrtr_keys)

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => -32_603, "message" => "Internal server error"}} =
                   dispatch(deploy())
        end)

      assert log =~ ":mrtr_keys"
    end

    test "an unsealable state or a malformed input request is -32603" do
      roots = %{"roots" => %{}}

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => -32_603}} =
                   dispatch(modern("tools/call", %{"name" => "pid_state"}, roots))

          assert %{"error" => %{"code" => -32_603}} =
                   dispatch(modern("tools/call", %{"name" => "bogus"}, roots))
        end)

      assert log =~ "JSON-encodable"
      assert log =~ "malformed input requests"
    end
  end

  test "resources/read: input_required carries no cache hints, then completes" do
    request = modern("resources/read", %{"uri" => "doc://secret"})
    %{"result" => result} = dispatch(request)

    assert :ok == McpSchema.validate(@version, "InputRequiredResult", result)
    assert result["resultType"] == "input_required"
    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "cacheScope")

    assert %{"result" => %{"resultType" => "complete", "contents" => [%{"text" => "revealed"}]}} =
             dispatch(retry(request, result["requestState"], %{}))
  end

  test "prompts/get: a DSL get handler's input_required is passed through unwrapped" do
    request = modern("prompts/get", %{"name" => "confirm"})
    %{"result" => result} = dispatch(request)

    assert :ok == McpSchema.validate(@version, "InputRequiredResult", result)
    refute Map.has_key?(result, "messages")

    assert %{"result" => %{"resultType" => "complete", "messages" => [%{"role" => "user"}]}} =
             dispatch(retry(request, result["requestState"], %{}))
  end

  test "a token sealed for one server module does not open at another" do
    alice = ConduitMcp.Principal.put(conn(:post, "/", ""), %{id: "alice"})
    %{"result" => %{"requestState" => token}} = dispatch(deploy(), alice)

    assert {:reply, %{"error" => %{"code" => -32_602, "message" => "Invalid requestState"}}} =
             Handler.dispatch(retry(deploy(), token, @approve), OtherDeployServer, alice)
  end

  test "a token minted for one method does not open on another" do
    %{"result" => %{"requestState" => token}} = dispatch(deploy())

    assert %{"error" => %{"code" => -32_602, "message" => "Invalid requestState"}} =
             dispatch(retry(modern("prompts/get", %{"name" => "confirm"}), token, %{}))
  end

  test "the legacy era answers {:input_required, ...} with -32603" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "deploy", "arguments" => %{"target" => "prod"}}
    }

    log =
      capture_log(fn ->
        assert %{
                 "error" => %{
                   "code" => -32_603,
                   "message" => "MRTR input requests require protocol 2026-07-28"
                 }
               } = dispatch(request)
      end)

    assert log =~ "handle_call_tool"
  end
end
