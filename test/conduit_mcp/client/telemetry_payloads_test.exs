defmodule ConduitMcp.Client.TelemetryPayloadsTest do
  # TL-2: opt-in capture of tool-call arguments and results in the
  # `tool_call` span. The span runs in the caller, so a handler attached
  # from the test process sees exactly this test's emissions.
  use ExUnit.Case, async: true

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Config, Hub, Secret, Telemetry, ToolResult}
  alias ConduitMcp.Client.Transport.InProcess
  alias ConduitMcp.TelemetryTestHelper

  @start [:conduit_mcp, :client, :tool_call, :start]
  @stop [:conduit_mcp, :client, :tool_call, :stop]
  @arg "ARG-tl2-5c1f09ad"
  @redacted "[#{byte_size(@arg)} bytes]"
  @transport {InProcess, server: __MODULE__.Server}

  defmodule Server do
    use ConduitMcp.Server

    tool "echo", "Echoes the message" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => message} -> text("echo: " <> message) end)
    end

    tool "report", "Structured output" do
      param(:message, :string, "Message", required: true)

      handle(fn _conn, %{"message" => message} ->
        structured(%{"length" => String.length(message)}, "done")
      end)
    end
  end

  defp start_client(opts) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client, [name: name, server_id: "srv", protocol: :modern, transport: @transport] ++ opts},
      id: name
    )

    assert :ok = Client.await_ready(name)
    name
  end

  defp attach, do: TelemetryTestHelper.attach_event_handlers(self(), [@start, @stop])

  # Replaces every string with its byte size: a realistic host redactor.
  defp redact(%{} = map), do: Map.new(map, fn {key, value} -> {key, redact(value)} end)
  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(string) when is_binary(string), do: "[#{byte_size(string)} bytes]"
  defp redact(other), do: other

  defp capture(opts \\ []), do: [telemetry: [capture_payloads: [redact: &redact/1] ++ opts]]

  describe "default (off)" do
    test "start and stop have no :arguments or :result key" do
      name = start_client([])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => @arg})

      assert_received {@start, ^ref, _, start_meta}
      assert_received {@stop, ^ref, _, stop_meta}

      refute Map.has_key?(start_meta, :arguments)
      refute Map.has_key?(stop_meta, :result)
      refute inspect({start_meta, stop_meta}) =~ @arg
    end

    test "capture_payloads: false is the same as the default" do
      name = start_client(telemetry: [capture_payloads: false])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => @arg})

      assert_received {@start, ^ref, _, start_meta}
      assert_received {@stop, ^ref, _, stop_meta}
      refute Map.has_key?(start_meta, :arguments)
      refute Map.has_key?(stop_meta, :result)
    end
  end

  describe "enabled" do
    test "start carries redacted arguments and stop the redacted result" do
      name = start_client(capture())
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => @arg})

      assert_received {@start, ^ref, _, %{arguments: arguments}}
      assert arguments == %{"message" => @redacted}

      assert_received {@stop, ^ref, _, %{result: result}}

      assert result == %{
               "content" => [
                 %{"type" => "[4 bytes]", "text" => "[#{byte_size("echo: " <> @arg)} bytes]"}
               ],
               "isError" => false
             }
    end

    test "the result includes structuredContent when the server sent it" do
      name = start_client(telemetry: [capture_payloads: [redact: & &1]])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "report", %{"message" => "abc"})

      assert_received {@stop, ^ref, _, %{result: %{"structuredContent" => %{"length" => 3}}}}
    end

    test "an error outcome has result nil" do
      name = start_client(capture())
      ref = attach()

      assert {:error, _} = Client.call_tool(name, "missing", %{"message" => @arg})

      assert_received {@start, ^ref, _, %{arguments: %{"message" => @redacted}}}
      assert_received {@stop, ^ref, _, %{result: nil, status: :error}}
    end

    test "the governed pipeline captures the arguments given and the result returned" do
      name =
        start_client(
          capture() ++
            [
              policy: [allow: ["srv/*"]],
              hooks: [pre_tool_call: [{:all, fn _call, _ctx -> :cont end, id: :pass}]]
            ]
        )

      ref = attach()

      assert {:ok, %ToolResult{}} =
               Client.call_tool(name, "echo", %{"message" => @arg}, principal: "alice")

      assert_received {@start, ^ref, _, %{arguments: %{"message" => @redacted}}}
      assert_received {@stop, ^ref, _, %{result: %{"isError" => false, "content" => [_]}}}
    end

    test "a redact that raises, throws or exits gives :redaction_failed" do
      for redact <- [
            fn _ -> raise "redactor bug: #{@arg}" end,
            fn _ -> throw(@arg) end,
            fn _ -> exit(@arg) end
          ] do
        name = start_client(telemetry: [capture_payloads: [redact: redact]])
        ref = attach()

        assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => @arg})

        assert_received {@start, ^ref, _, %{arguments: :redaction_failed} = start_meta}
        assert_received {@stop, ^ref, _, %{result: :redaction_failed} = stop_meta}
        refute inspect({start_meta, stop_meta}) =~ @arg
      end
    end

    test "a Secret returned by redact gives :redaction_failed, never the secret" do
      # `redact` leaves (here: puts) a Secret in the value it returns.
      redact = fn value -> %{"kept" => value, "token" => Secret.new(@arg)} end
      name = start_client(telemetry: [capture_payloads: [redact: redact]])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => "x"})

      assert_received {@start, ^ref, _, %{arguments: :redaction_failed}}
      assert_received {@stop, ^ref, _, %{result: :redaction_failed}}
    end

    test "a Secret in the arguments, passed through as-is, gives :redaction_failed" do
      capture = %{redact: & &1, max_bytes: 4_096}
      args = %{"message" => "x", "token" => Secret.new(@arg)}

      assert Telemetry.payload(capture, args) == :redaction_failed
    end

    test "a return that cannot be JSON-encoded gives :redaction_failed" do
      name = start_client(telemetry: [capture_payloads: [redact: fn value -> {:raw, value} end]])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => @arg})

      assert_received {@start, ^ref, _, %{arguments: :redaction_failed}}
      assert_received {@stop, ^ref, _, %{result: :redaction_failed}}
    end

    test "a value over max_bytes is {:truncated, byte_size}, never partial" do
      name = start_client(telemetry: [capture_payloads: [redact: & &1, max_bytes: 10]])
      ref = attach()
      args = %{"message" => @arg}

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", args)

      size = args |> JSON.encode!() |> byte_size()
      assert_received {@start, ^ref, _, %{arguments: {:truncated, ^size}}}
      assert_received {@stop, ^ref, _, %{result: {:truncated, n}}}
      assert n > 10
    end

    test "a value within max_bytes passes" do
      name = start_client(telemetry: [capture_payloads: [redact: & &1, max_bytes: 4_096]])
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"message" => "hi"})

      assert_received {@start, ^ref, _, %{arguments: %{"message" => "hi"}}}
    end
  end

  describe "configuration" do
    test "max_bytes defaults to 4 096" do
      config =
        Config.new!(
          name: :tl2,
          transport: @transport,
          telemetry: [capture_payloads: [redact: & &1]]
        )

      assert %{max_bytes: 4_096, redact: redact} = config.capture_payloads
      assert is_function(redact, 1)
      assert Config.new!(name: :tl2, transport: @transport).capture_payloads == false
    end

    test "capture_payloads: true is rejected, naming :redact" do
      error =
        assert_raise ArgumentError, fn ->
          Config.new!(name: :tl2, transport: @transport, telemetry: [capture_payloads: true])
        end

      assert error.message =~ ":capture_payloads"
      assert error.message =~ ":redact"
    end

    test "max_bytes without :redact is rejected, naming :redact" do
      error =
        assert_raise ArgumentError, fn ->
          Config.new!(
            name: :tl2,
            transport: @transport,
            telemetry: [capture_payloads: [max_bytes: 10]]
          )
        end

      assert error.message =~ ":capture_payloads"
      assert error.message =~ ":redact"
    end

    test "a bad max_bytes, redact or value is rejected" do
      for capture <- [[redact: & &1, max_bytes: 0], [redact: fn -> :x end], :yes] do
        assert_raise ArgumentError, ~r/:capture_payloads/, fn ->
          Config.new!(name: :tl2, transport: @transport, telemetry: [capture_payloads: capture])
        end
      end
    end

    test "a hub rejects capture_payloads without :redact, at the hub and per server" do
      assert_raise ArgumentError, ~r/:redact/, fn ->
        Hub.Config.new!(name: :tl2_hub, policy: :allow_all, telemetry: [capture_payloads: true])
      end

      assert_raise ArgumentError, ~r/:redact/, fn ->
        Hub.Config.new!(
          name: :tl2_hub,
          policy: :allow_all,
          servers: [
            {"alpha", [transport: @transport, telemetry: [capture_payloads: [max_bytes: 10]]]}
          ]
        )
      end
    end

    test "a hub server entry accepts the option; the hub's default applies to the others" do
      config =
        Hub.Config.new!(
          name: :tl2_hub,
          policy: :allow_all,
          telemetry: [capture_payloads: [redact: & &1, max_bytes: 64]],
          servers: [
            {"alpha", [transport: @transport]},
            {"beta", [transport: @transport, telemetry: [capture_payloads: false]]}
          ]
        )

      [{"alpha", alpha}, {"beta", beta}] = config.servers
      assert %{max_bytes: 64} = alpha.capture_payloads
      assert beta.capture_payloads == false
    end

    test "a hub server with capture on emits redacted payloads" do
      hub = {__MODULE__, make_ref()}

      start_supervised!(
        {Hub,
         name: hub,
         policy: :allow_all,
         servers: [{"alpha", [transport: @transport] ++ capture()}],
         restart_backoff: fn _ -> 0 end},
        id: hub
      )

      ConduitMcp.Test.Client.Harness.await_hub_ready(hub, ["alpha"])
      client = Hub.client(hub, "alpha")
      ref = attach()

      assert {:ok, %ToolResult{}} = Client.call_tool(client, "echo", %{"message" => @arg})

      assert_received {@start, ^ref, _, %{arguments: %{"message" => @redacted}}}
      assert_received {@stop, ^ref, _, %{result: %{"isError" => false}}}
    end
  end
end
