defmodule ConduitMcp.ProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Protocol

  # T-L1: three of the original five properties could not reach the input space
  # they claimed. `string(:alphanumeric)` cannot practically generate the keys
  # `"jsonrpc"`/`"method"`/`"id"`, so every generated map took the same
  # fall-through and `valid_request?`/`valid_notification?`'s `true` branch was
  # never reached; `:alphanumeric` also excludes `/`, so no real MCP method name
  # was ever generated and only `method_not_found` was exercised.

  # Built from the fixed key set the predicates actually look at, each key
  # independently present or absent, so both branches are reachable. (`map_of`
  # over a 4-element key space just collides.)
  defp protocol_ish_map do
    gen all(
          jsonrpc <- one_of([constant("2.0"), string(:printable), constant(:absent)]),
          method <- one_of([mcp_method(), integer(), constant(:absent)]),
          id <- one_of([integer(), string(:alphanumeric, min_length: 1), constant(:absent)]),
          params <- one_of([map_of(string(:alphanumeric), integer()), constant(:absent)]),
          extra <- map_of(string(:alphanumeric, min_length: 5), integer())
        ) do
      extra
      |> maybe_put("jsonrpc", jsonrpc)
      |> maybe_put("method", method)
      |> maybe_put("id", id)
      |> maybe_put("params", params)
    end
  end

  defp maybe_put(map, _key, :absent), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp mcp_method do
    one_of([
      member_of(Map.keys(Protocol.methods())),
      # Real method names contain "/", which `string(:alphanumeric)` excludes.
      map({string(:alphanumeric, min_length: 1), string(:alphanumeric, min_length: 1)}, fn
        {a, b} -> a <> "/" <> b
      end)
    ])
  end

  property "valid_request? never crashes" do
    check all(map <- protocol_ish_map()) do
      assert is_boolean(Protocol.valid_request?(map))
    end
  end

  test "the generator reaches both branches of valid_request? and valid_notification?" do
    # T-L1's whole point was that the old generator could not reach the `true`
    # branch, and `assert is_boolean/1` above cannot tell. If `maybe_put/3`
    # regresses - or `@protocol_keys` loses `"jsonrpc"` - the properties stay
    # green while silently covering a single fall-through again. This is the
    # assertion that fails instead.
    maps = Enum.take(protocol_ish_map(), 400)

    requests = Enum.map(maps, &Protocol.valid_request?/1)
    notifications = Enum.map(maps, &Protocol.valid_notification?/1)

    assert Enum.any?(requests), "generator never produced a valid request"
    assert Enum.any?(requests, &(not &1)), "generator never produced an invalid request"
    assert Enum.any?(notifications), "generator never produced a valid notification"

    assert Enum.any?(notifications, &(not &1)),
           "generator never produced an invalid notification"
  end

  property "a well-formed request is always accepted, a request without an id never is" do
    check all(
            method <- mcp_method(),
            id <- one_of([integer(), string(:alphanumeric, min_length: 1)])
          ) do
      assert Protocol.valid_request?(%{"jsonrpc" => "2.0", "method" => method, "id" => id})
      refute Protocol.valid_request?(%{"jsonrpc" => "2.0", "method" => method})
      refute Protocol.valid_request?(%{"jsonrpc" => "1.0", "method" => method, "id" => id})
    end
  end

  property "a request without an id is a valid notification" do
    check all(method <- mcp_method()) do
      assert Protocol.valid_notification?(%{"jsonrpc" => "2.0", "method" => method})
      refute Protocol.valid_notification?(%{"jsonrpc" => "2.0", "method" => method, "id" => 1})
    end
  end

  property "valid_notification? never crashes on arbitrary maps" do
    check all(map <- protocol_ish_map()) do
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

  property "handle_request never crashes on arbitrary method names, including MCP-shaped ones" do
    check all(
            method <- mcp_method(),
            id <- integer(1..100_000)
          ) do
      request = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}}

      result = ConduitMcp.Handler.handle_request(request, ConduitMcp.TestServer)
      assert is_map(result)
      assert result["jsonrpc"] == "2.0"
      assert result["id"] == id
    end
  end

  # Two high-value invariants the suite did not state anywhere.

  property "every response is string-key closed at every depth" do
    # The repo's central documented convention — the wire format is
    # string-keyed JSON — was enforced nowhere.
    check all(
            id <- one_of([integer(), string(:alphanumeric), constant(nil)]),
            result <- nested_string_keyed_map()
          ) do
      assert string_keyed?(Protocol.success_response(id, result))
      assert string_keyed?(Protocol.error_response(id, -32_000, "boom", result))
    end
  end

  defp nested_string_keyed_map do
    leaf = one_of([string(:printable), integer(), boolean(), constant(nil)])

    map_of(
      string(:alphanumeric, min_length: 1),
      one_of([leaf, map_of(string(:alphanumeric, min_length: 1), leaf)])
    )
  end

  defp string_keyed?(value) when is_map(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and string_keyed?(v) end)
  end

  defp string_keyed?(value) when is_list(value), do: Enum.all?(value, &string_keyed?/1)
  defp string_keyed?(_value), do: true
end
