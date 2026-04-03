defmodule ConduitMcp.ProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Protocol

  property "valid_request? never crashes on arbitrary maps" do
    check all(map <- map_of(string(:alphanumeric), term())) do
      assert is_boolean(Protocol.valid_request?(map))
    end
  end

  property "valid_notification? never crashes on arbitrary maps" do
    check all(map <- map_of(string(:alphanumeric), term())) do
      assert is_boolean(Protocol.valid_notification?(map))
    end
  end

  property "success_response always produces valid JSON-RPC shape" do
    check all(
            id <- one_of([integer(), string(:alphanumeric)]),
            result <- map_of(string(:alphanumeric), string(:alphanumeric))
          ) do
      resp = Protocol.success_response(id, result)
      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == id
      assert resp["result"] == result
    end
  end

  property "error_response always produces valid JSON-RPC error shape" do
    check all(
            id <- one_of([integer(), string(:alphanumeric), constant(nil)]),
            code <- integer(),
            message <- string(:alphanumeric)
          ) do
      resp = Protocol.error_response(id, code, message)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["code"] == code
      assert resp["error"]["message"] == message
    end
  end

  property "handle_request never crashes on random method names" do
    check all(
            method <- string(:alphanumeric, min_length: 1),
            id <- integer(1..100_000)
          ) do
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method
      }

      result = ConduitMcp.Handler.handle_request(request, ConduitMcp.TestServer)
      assert is_map(result)
      assert result["jsonrpc"] == "2.0"
    end
  end
end
