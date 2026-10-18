defmodule ConduitMcp.DiscoverTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Discover
  alias ConduitMcp.Handler

  defmodule DslWithInstructions do
    use ConduitMcp.Server, instructions: "Search before you fetch."

    tool "echo", "Echo" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => m} -> text(m) end)
    end
  end

  defmodule ManualWithInstructions do
    use ConduitMcp.Server, dsl: false, instructions: "Manual mode guidance."
  end

  defmodule NoInstructions do
    use ConduitMcp.Server, dsl: false
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, description: "Echo"

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule EndpointWithInstructions do
    use ConduitMcp.Endpoint,
      name: "Ep",
      version: "2.0.0",
      instructions: "Endpoint guidance."

    component(EchoTool)
  end

  defmodule SubscribingServer do
    use ConduitMcp.Server, dsl: false

    def handle_subscribe_resource(_conn, _uri), do: {:ok, %{}}
  end

  defp transport_conn(instructions) do
    Plug.Conn.put_private(%Plug.Conn{}, :instructions, instructions)
  end

  describe "instructions/2" do
    test "comes from use ConduitMcp.Server in DSL and manual mode" do
      assert Discover.instructions(DslWithInstructions, %Plug.Conn{}) ==
               "Search before you fetch."

      assert Discover.instructions(ManualWithInstructions, %Plug.Conn{}) ==
               "Manual mode guidance."
    end

    test "comes from the Endpoint option, which __endpoint_config__/0 exposes" do
      assert Discover.instructions(EndpointWithInstructions, %Plug.Conn{}) ==
               "Endpoint guidance."

      assert EndpointWithInstructions.__endpoint_config__()[:instructions] ==
               "Endpoint guidance."
    end

    test "the transport option overrides the module's" do
      assert Discover.instructions(DslWithInstructions, transport_conn("From the transport.")) ==
               "From the transport."

      assert Discover.instructions(NoInstructions, transport_conn("From the transport.")) ==
               "From the transport."
    end

    test "is nil when nothing declares any" do
      assert Discover.instructions(NoInstructions, %Plug.Conn{}) == nil
      assert Discover.instructions(NoInstructions, transport_conn(nil)) == nil
    end
  end

  describe "result/2" do
    test "advertises every supported version and the server's capabilities" do
      result = Discover.result(EndpointWithInstructions, %Plug.Conn{})

      assert result["supportedVersions"] == ["2026-07-28", "2025-11-25", "2025-06-18"]
      assert result["capabilities"] == %{"tools" => %{"listChanged" => true}, "logging" => %{}}
      assert result["instructions"] == "Endpoint guidance."
    end

    test "omits instructions when there are none" do
      refute Map.has_key?(Discover.result(NoInstructions, %Plug.Conn{}), "instructions")
    end

    # Modern resource subscription is `subscriptions/listen`'s
    # `resourceSubscriptions`, which every server answers - whether or not
    # it implements the legacy `resources/subscribe` callback.
    test "advertises listen-backed change notifications, regardless of legacy callbacks" do
      legacy = ConduitMcp.Capabilities.build(SubscribingServer)
      modern = Discover.result(SubscribingServer, %Plug.Conn{})["capabilities"]
      no_callback = Discover.result(NoInstructions, %Plug.Conn{})["capabilities"]

      assert legacy["resources"] == %{"listChanged" => false, "subscribe" => true}

      for caps <- [modern, no_callback] do
        assert caps["resources"] == %{"listChanged" => true, "subscribe" => true}
        assert caps["tools"] == %{"listChanged" => true}
        assert caps["prompts"] == %{"listChanged" => true}
      end
    end
  end

  describe "the legacy initialize result" do
    defp initialize(server, conn) do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}
      }

      Handler.handle_request(request, server, conn)["result"]
    end

    test "returns the same instructions server/discover does" do
      for server <- [DslWithInstructions, ManualWithInstructions, EndpointWithInstructions] do
        discover = %{"jsonrpc" => "2.0", "id" => 2, "method" => "server/discover"}
        {:reply, %{"result" => discovered}} = Handler.dispatch(discover, server, %Plug.Conn{})

        assert initialize(server, %Plug.Conn{})["instructions"] == discovered["instructions"]
        assert is_binary(discovered["instructions"])
      end

      assert initialize(DslWithInstructions, transport_conn("Override."))["instructions"] ==
               "Override."
    end

    test "has no instructions member when there are none" do
      refute Map.has_key?(initialize(NoInstructions, %Plug.Conn{}), "instructions")
    end
  end

  describe "the transport :instructions option" do
    test "is resolved into conn.private at init" do
      opts =
        ConduitMcp.Transport.Shared.init(
          [server_module: NoInstructions, allowed_origins: "*", instructions: "Via transport."],
          ConduitMcp.Transport.StreamableHTTP
        )

      assert opts[:shared_private][:instructions] == "Via transport."
    end

    test "rejects a non-string at boot" do
      assert_raise ArgumentError, ~r/:instructions must be a string/, fn ->
        ConduitMcp.Transport.Shared.init(
          [server_module: NoInstructions, allowed_origins: "*", instructions: [:nope]],
          ConduitMcp.Transport.StreamableHTTP
        )
      end
    end
  end
end
