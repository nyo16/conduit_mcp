defmodule ConduitMcp.Client.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Backoff
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Request

  @modern %{
    era: :modern,
    version: "2026-07-28",
    client_capabilities: %{"sampling" => %{}},
    client_info: %{"name" => "c", "version" => "1"}
  }

  describe "envelope/2" do
    test "modern requests carry the version, capabilities and client info" do
      params = Request.envelope(%{"name" => "echo"}, @modern)

      assert params["_meta"] == %{
               "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
               "io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}},
               "io.modelcontextprotocol/clientInfo" => %{"name" => "c", "version" => "1"}
             }
    end

    test "logLevel and progressToken are added when set" do
      meta =
        Request.envelope(%{}, Map.merge(@modern, %{log_level: "info", progress_token: 3}))[
          "_meta"
        ]

      assert meta["io.modelcontextprotocol/logLevel"] == "info"
      assert meta["progressToken"] == 3
    end

    test "reserved keys win over user _meta, which is otherwise kept" do
      user_meta = %{
        "io.modelcontextprotocol/protocolVersion" => "1999-01-01",
        "io.modelcontextprotocol/related" => "forged",
        "dev.mcp/anything" => "forged",
        "progressToken" => "forged",
        "example.com/trace" => "kept",
        "plain" => 1
      }

      meta = Request.envelope(%{"_meta" => user_meta}, @modern)["_meta"]

      assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      refute Map.has_key?(meta, "io.modelcontextprotocol/related")
      refute Map.has_key?(meta, "dev.mcp/anything")
      refute Map.has_key?(meta, "progressToken")
      assert meta["example.com/trace"] == "kept"
      assert meta["plain"] == 1
    end

    test "a legacy request without progress or user _meta sends no _meta" do
      info = %{@modern | era: :legacy}
      assert Request.envelope(%{"uri" => "a"}, info) == %{"uri" => "a"}

      assert Request.envelope(%{"uri" => "a", "_meta" => %{"progressToken" => 1}}, info) ==
               %{"uri" => "a"}
    end
  end

  describe "run/4 and call/3 without a client" do
    test "an unknown client is :unavailable, never an exit" do
      name = {__MODULE__, make_ref()}

      assert {:error, %Error{kind: :unavailable, reason: :not_started}} =
               Request.run(name, "tools/list")

      assert {:error, %Error{kind: :unavailable, reason: :not_started}} =
               Request.call(name, :await_ready, 10)

      assert {:error, %Error{kind: :unavailable}} = ConduitMcp.Client.status(name)
    end

    test "unknown request options raise" do
      assert_raise ArgumentError, fn -> Request.run(:anyone, "tools/list", %{}, tmeout: 1) end
    end
  end

  property "full-jitter backoff stays within 1..min(cap, base * 2^attempt)" do
    check all(attempt <- integer(0..100)) do
      delay = Backoff.full_jitter(attempt)
      assert delay >= 1
      assert delay <= min(30_000, 500 * 2 ** min(attempt, 16))
    end
  end
end
