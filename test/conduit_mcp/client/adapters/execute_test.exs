defmodule ConduitMcp.Client.Adapters.ExecuteTest do
  # `ConduitMcp.Client.Adapters.tools/3` and `execute_tool_calls/4` against a
  # hub and a single client over `ConduitMcp.Client.Transport.InProcess`.
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness, only: [eventually: 1]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Adapters, Hub, ToolCall, ToolSet}
  alias ConduitMcp.Client.Transport.InProcess
  alias ConduitMcp.TelemetryTestHelper

  defmodule Server do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(conn), do: {:ok, %{"tools" => conn.assigns.tools}}

    @impl true
    def handle_call_tool(conn, name, params) do
      send(conn.assigns.test_pid, {:called, conn.assigns.server, name, params})

      case name do
        "fail" ->
          {:ok, %{"content" => [%{"type" => "text", "text" => "it broke"}], "isError" => true}}

        "block" ->
          receive do: (:never -> {:ok, %{}})

        "structured" ->
          {:ok, %{"content" => [], "structuredContent" => %{"n" => 1}}}

        _other ->
          {:ok, %{"content" => [%{"type" => "text", "text" => "#{conn.assigns.server}:#{name}"}]}}
      end
    end
  end

  @open_schema %{
    "type" => "object",
    "properties" => %{"q" => %{"type" => "string"}},
    "additionalProperties" => true
  }

  @tools [
    %{"name" => "echo", "inputSchema" => %{"type" => "object"}},
    %{"name" => "fail", "inputSchema" => %{"type" => "object"}},
    %{"name" => "block", "inputSchema" => %{"type" => "object"}},
    %{"name" => "guarded", "inputSchema" => %{"type" => "object"}},
    %{"name" => "structured", "inputSchema" => %{"type" => "object"}},
    %{"name" => "open", "inputSchema" => @open_schema}
  ]

  setup do
    {:ok, hub: {__MODULE__, make_ref()}}
  end

  defp transport(id),
    do: {InProcess, server: Server, assigns: %{tools: @tools, test_pid: self(), server: id}}

  defp policy, do: [allow: ["*/*"], allow_new_tools: true, pin_tools: false, ask: ["*/guarded"]]

  defp on_ask(call, _ctx),
    do: if(call.name == "guarded", do: {:deny, :stop_now, :halt}, else: {:allow, :once})

  defp start_hub(hub) do
    start_supervised!(
      {Hub,
       name: hub,
       policy: policy(),
       on_ask: &on_ask/2,
       restart_backoff: fn _ -> 0 end,
       servers: [
         {"alpha", [transport: transport("alpha")]},
         {"beta", [transport: transport("beta")]}
       ]}
    )

    eventually(fn ->
      Enum.all?(["alpha", "beta"], &(Client.await_ready(Hub.client(hub, &1), 1_000) == :ok))
    end)
  end

  defp use_block(id, name, input \\ %{}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp text(%{"content" => [%{"type" => "text", "text" => text} | _]}), do: text

  defp assert_no_tasks(hub),
    do: eventually(fn -> Task.Supervisor.children(Hub.task_sup(hub)) == [] end)

  describe "Anthropic" do
    test "mixed success, is_error, unknown and invalid calls keep the model's order", %{hub: hub} do
      start_hub(hub)
      {:ok, listing} = Adapters.tools(hub, :anthropic, cache_control: :last)
      assert Enum.map(listing.tools, & &1["name"]) == ToolSet.names(listing.toolset)
      assert List.last(listing.tools)["cache_control"] == %{"type" => "ephemeral"}

      response = %{
        "content" => [
          %{"type" => "text", "text" => "Let me check."},
          use_block("1", "alpha__echo", %{"x" => 1}),
          use_block("2", "gamma__echo"),
          use_block("3", "beta__fail"),
          use_block("4", "alpha__echo", "not an object"),
          use_block("5", "beta__echo")
        ]
      }

      assert {:ok, results} =
               Adapters.execute_tool_calls(hub, :anthropic, response, toolset: listing.toolset)

      assert Enum.map(results, & &1["tool_use_id"]) == ["1", "2", "3", "4", "5"]
      assert Enum.map(results, & &1["is_error"]) == [false, true, true, true, false]
      assert Enum.map(results, &text/1) |> Enum.at(0) == "alpha:echo"
      assert text(Enum.at(results, 1)) =~ "unknown tool"
      assert text(Enum.at(results, 2)) == "it broke"
      assert text(Enum.at(results, 3)) =~ "must be a JSON object"

      assert_received {:called, "alpha", "echo", %{"x" => 1}}
      assert_received {:called, "beta", "fail", _}
      assert_received {:called, "beta", "echo", _}
      refute_received {:called, _, _, _}
      assert_no_tasks(hub)
    end

    test "a halting deny returns {:halt, results}", %{hub: hub} do
      start_hub(hub)

      response = [use_block("a", "alpha__guarded"), use_block("b", "beta__echo")]
      assert {:halt, [denied, ok]} = Adapters.execute_tool_calls(hub, :anthropic, response)

      assert %{"tool_use_id" => "a", "is_error" => true} = denied
      assert text(denied) =~ "ask_halt"
      assert %{"tool_use_id" => "b", "is_error" => false} = ok
      refute_received {:called, "alpha", "guarded", _}
    end

    test "a call over :call_timeout is answered as a timeout, in order", %{hub: hub} do
      start_hub(hub)

      response = [use_block("1", "alpha__block"), use_block("2", "beta__echo")]

      assert {:ok, [timed_out, ok]} =
               Adapters.execute_tool_calls(hub, :anthropic, response,
                 call_timeout: 200,
                 max_concurrency: 1
               )

      assert %{"tool_use_id" => "1", "is_error" => true} = timed_out
      assert text(timed_out) =~ "timeout"
      assert %{"tool_use_id" => "2", "is_error" => false} = ok
      assert_no_tasks(hub)
    end

    test "ToolCall lists run too; a call outside the toolset sends nothing", %{hub: hub} do
      start_hub(hub)

      calls = [
        ToolCall.new("beta", "echo", %{}, call_id: "x"),
        ToolCall.new("alpha", "missing", %{}, call_id: "y")
      ]

      assert {:ok, [ok, unknown]} = Adapters.execute_tool_calls(hub, :anthropic, calls)
      assert %{"tool_use_id" => "x", "is_error" => false} = ok
      assert %{"tool_use_id" => "y", "is_error" => true} = unknown
      assert_received {:called, "beta", "echo", _}
      refute_received {:called, "alpha", _, _}
      assert {:ok, []} = Adapters.execute_tool_calls(hub, :anthropic, [])
    end
  end

  describe "OpenAI" do
    test "tools/3 emits strict_fallback; chat calls answer in order", %{hub: hub} do
      start_hub(hub)

      ref =
        TelemetryTestHelper.attach_event_handlers(
          self(),
          [[:conduit_mcp, :client, :adapter, :strict_fallback]]
        )

      {:ok, listing} = Adapters.tools(hub, :openai, api: :chat)

      for name <- ["alpha__open", "beta__open"] do
        assert_received {_, ^ref, %{count: 1},
                         %{
                           client: ^hub,
                           api: :chat,
                           tool_name: ^name,
                           reason: :unsupported_keyword
                         }}
      end

      open = Enum.find(listing.tools, &(&1["function"]["name"] == "alpha__open"))
      assert open["function"]["strict"] == false

      response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "beta__echo", "arguments" => "{}"}
                },
                %{
                  "id" => "c2",
                  "type" => "function",
                  "function" => %{"name" => "nope", "arguments" => "{}"}
                },
                %{
                  "id" => "c3",
                  "type" => "function",
                  "function" => %{"name" => "alpha__fail", "arguments" => ""}
                }
              ]
            }
          }
        ]
      }

      assert {:ok, results} =
               Adapters.execute_tool_calls(hub, :openai, response,
                 api: :chat,
                 toolset: listing.toolset,
                 null_paths: listing.null_paths
               )

      assert [
               %{"role" => "tool", "tool_call_id" => "c1", "content" => "beta:echo"},
               %{"role" => "tool", "tool_call_id" => "c2", "content" => unknown},
               %{"role" => "tool", "tool_call_id" => "c3", "content" => "Error: it broke"}
             ] = results

      assert unknown =~ "unknown tool"
    end

    test "Responses output items answer as function_call_output", %{hub: hub} do
      start_hub(hub)

      response = %{
        "output" => [
          %{"type" => "reasoning", "summary" => []},
          %{
            "type" => "function_call",
            "call_id" => "r1",
            "name" => "alpha__echo",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call",
            "call_id" => "r2",
            "name" => "alpha__guarded",
            "arguments" => "{}"
          }
        ]
      }

      assert {:halt, [first, second]} =
               Adapters.execute_tool_calls(hub, :openai, response, api: :responses)

      assert first == %{
               "type" => "function_call_output",
               "call_id" => "r1",
               "output" => "alpha:echo"
             }

      assert %{"call_id" => "r2", "output" => "Error: " <> _} = second

      assert_raise ArgumentError, ~r/:api/, fn ->
        Adapters.execute_tool_calls(hub, :openai, response)
      end
    end
  end

  describe "Gemini" do
    test "function responses carry the exposed name and id", %{hub: hub} do
      start_hub(hub)

      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"functionCall" => %{"id" => "g1", "name" => "beta__structured", "args" => %{}}},
                %{"text" => "thinking"},
                %{"functionCall" => %{"name" => "nope"}}
              ]
            }
          }
        ]
      }

      assert {:ok, [structured, unknown]} = Adapters.execute_tool_calls(hub, :gemini, response)

      assert structured == %{
               "functionResponse" => %{
                 "id" => "g1",
                 "name" => "beta__structured",
                 "response" => %{"output" => %{"n" => 1}}
               }
             }

      assert %{"functionResponse" => %{"name" => "nope", "response" => %{"error" => _}}} = unknown
    end
  end

  describe "a single client" do
    test "uses bare tool names and its own task supervisor" do
      name = {__MODULE__, make_ref()}

      start_supervised!(
        {Client, name: name, transport: transport("solo"), policy: policy(), on_ask: &on_ask/2}
      )

      {:ok, listing} = Adapters.tools(name, :gemini)

      assert ToolSet.names(listing.toolset) == [
               "echo",
               "fail",
               "block",
               "guarded",
               "structured",
               "open"
             ]

      calls = [
        %{"functionCall" => %{"id" => "1", "name" => "echo", "args" => %{}}},
        %{"functionCall" => %{"id" => "2", "name" => "guarded", "args" => %{}}}
      ]

      assert {:halt, [ok, denied]} =
               Adapters.execute_tool_calls(name, :gemini, calls, toolset: listing.toolset)

      assert %{
               "functionResponse" => %{"name" => "echo", "response" => %{"output" => "solo:echo"}}
             } = ok

      assert %{"functionResponse" => %{"response" => %{"error" => _}}} = denied
      assert_received {:called, "solo", "echo", _}
      refute_received {:called, _, "guarded", _}
    end
  end
end
