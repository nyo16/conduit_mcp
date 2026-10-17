defmodule ConduitMcp.Protocol.LegacyTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Protocol
  alias ConduitMcp.Protocol.Legacy

  doctest ConduitMcp.Protocol.Legacy

  test "shapes {:ok, result} as a success response" do
    assert Legacy.to_response("a", {:ok, %{"tools" => []}}) ==
             Protocol.success_response("a", %{"tools" => []})
  end

  test "nil data yields the same map as the 3-arity error_response, with no data member" do
    response = Legacy.to_response(7, {:error, -32602, "Missing uri", nil})

    assert response == Protocol.error_response(7, -32602, "Missing uri")
    refute Map.has_key?(response["error"], "data")
  end

  test "map data is carried in the error's data member" do
    data = %{"errors" => ["bad"]}

    assert Legacy.to_response(7, {:error, -32602, "Parameter validation failed", data}) ==
             %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{
                 "code" => -32602,
                 "message" => "Parameter validation failed",
                 "data" => data
               }
             }
  end
end
