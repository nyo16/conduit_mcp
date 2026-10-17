defmodule ConduitMcp.Client.NegotiationTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.{DiscoverResult, Error, Negotiation}
  alias ConduitMcp.Test.McpSchema

  doctest ConduitMcp.Client.Negotiation

  defmodule NoCallbacks do
    @moduledoc false
    @behaviour ConduitMcp.Client.Handler
    @impl true
    def handle_log(_level, _params, _ctx), do: :ok
    @impl true
    def handle_notification(_method, _params, _ctx), do: :ok
  end

  defmodule Sampler do
    @moduledoc false
    @behaviour ConduitMcp.Client.Handler
    @impl true
    def handle_sampling(_params, _ctx), do: {:ok, %{}}
  end

  defmodule FormElicitor do
    @moduledoc false
    @behaviour ConduitMcp.Client.Handler
    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "decline"}}
  end

  defmodule Everything do
    @moduledoc false
    @behaviour ConduitMcp.Client.Handler
    @impl true
    def handle_sampling(_params, _ctx), do: {:ok, %{}}
    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "cancel"}}
    @impl true
    def elicitation_modes, do: [:form, :url]
    @impl true
    def list_roots(_ctx), do: {:ok, %{"roots" => []}}
  end

  defmodule BadModes do
    @moduledoc false
    def handle_elicitation(_params, _ctx), do: {:ok, %{}}
    def elicitation_modes, do: [:popup]
  end

  @discover %{
    "resultType" => "complete",
    "supportedVersions" => ["2026-07-28", "2025-11-25"],
    "capabilities" => %{},
    "ttlMs" => 0,
    "cacheScope" => "public"
  }

  defp rpc_error(code, data \\ nil) do
    error = %{"code" => code, "message" => "err"}
    if data, do: Map.put(error, "data", data), else: error
  end

  defp rpc(body), do: Map.put(body, "jsonrpc", "2.0") |> Map.put("id", 1)

  describe "versions" do
    test "client versions, newest first" do
      assert Negotiation.client_versions() == ["2026-07-28", "2025-11-25", "2025-06-18"]
    end

    test "pick_version follows the client's preference, not the server's order" do
      assert Negotiation.pick_version(["2025-06-18", "2026-07-28"]) == {:ok, "2026-07-28"}
      assert Negotiation.pick_version(["2025-06-18"]) == {:ok, "2025-06-18"}
      assert Negotiation.pick_version([]) == {:error, :no_common_version}

      assert Negotiation.pick_version(["2026-07-28"], ["2025-11-25"]) ==
               {:error, :no_common_version}
    end

    test "era/1" do
      assert Negotiation.era("2026-07-28") == :modern
      assert Negotiation.era("2027-01-01") == :modern
      assert Negotiation.era("2025-06-18") == :legacy
      assert Negotiation.era("latest") == :unknown
    end
  end

  describe "classify_probe/3 on stdio" do
    test "a valid DiscoverResult is modern, with the picked version" do
      assert :ok = McpSchema.validate("2026-07-28", "DiscoverResult", @discover)

      assert {:modern, "2026-07-28", %DiscoverResult{}} =
               Negotiation.classify_probe(:stdio, {:result, @discover})
    end

    test "timeout or any non-modern error falls back to legacy (never keyed to one code)" do
      assert Negotiation.classify_probe(:stdio, :timeout) == :legacy

      for code <- [-32_601, -32_600, -32_602, -32_603, -32_000, 1, -32_002] do
        assert Negotiation.classify_probe(:stdio, {:error, rpc_error(code)}) == :legacy,
               "code #{code}"
      end

      assert Negotiation.classify_probe(:stdio, {:error, "garbage"}) == :legacy
    end

    test "a process exit during the probe reconnects as legacy" do
      assert Negotiation.classify_probe(:stdio, {:closed, {:exit_status, 1}}) ==
               {:reconnect, :legacy}
    end

    test "a non-discover result (a lenient legacy server) is legacy" do
      assert Negotiation.classify_probe(:stdio, {:result, %{}}) == :legacy
      assert Negotiation.classify_probe(:stdio, {:result, nil}) == :legacy
    end

    test "-32022 with a mutual modern version retries modern; never falls back" do
      error = rpc_error(-32_022, %{"supported" => ["2026-07-28"], "requested" => "2099-01-01"})

      assert Negotiation.classify_probe(:stdio, {:error, error}) ==
               {:modern_retry, "2026-07-28"}

      legacy_only =
        rpc_error(-32_022, %{"supported" => ["2025-11-25"], "requested" => "2026-07-28"})

      assert {:error, %Error{kind: :protocol, reason: :no_common_version}} =
               Negotiation.classify_probe(:stdio, {:error, legacy_only})

      assert {:error, %Error{reason: :no_common_version}} =
               Negotiation.classify_probe(:stdio, {:error, rpc_error(-32_022)})
    end

    test "-32021 and -32020 are typed errors, not fallback evidence" do
      required = %{"requiredCapabilities" => %{"sampling" => %{}}}

      assert {:error, %Error{kind: :protocol, reason: :missing_client_capability, data: data}} =
               Negotiation.classify_probe(:stdio, {:error, rpc_error(-32_021, required)})

      assert data["data"] == required

      assert {:error, %Error{reason: :header_mismatch}} =
               Negotiation.classify_probe(:stdio, {:error, rpc_error(-32_020)})
    end

    test "a discover-shaped but invalid result is a protocol error" do
      assert {:error, %Error{reason: :invalid_discover_result}} =
               Negotiation.classify_probe(
                 :stdio,
                 {:result, Map.delete(@discover, "capabilities")}
               )

      assert {:error, %Error{reason: :no_common_version}} =
               Negotiation.classify_probe(
                 :stdio,
                 {:result, Map.put(@discover, "supportedVersions", ["2025-11-25"])}
               )
    end

    test "the :versions option restricts the modern pick" do
      assert {:error, %Error{reason: :no_common_version}} =
               Negotiation.classify_probe(:stdio, {:result, @discover}, versions: ["2025-11-25"])
    end
  end

  describe "classify_probe/3 on HTTP" do
    @json "application/json"

    test "truth table" do
      modern_400 =
        JSON.encode!(rpc(%{"error" => rpc_error(-32_022, %{"supported" => ["2026-07-28"]})}))

      legacy_400 = JSON.encode!(rpc(%{"error" => rpc_error(-32_600)}))
      method_not_found = JSON.encode!(rpc(%{"error" => rpc_error(-32_601)}))
      internal = JSON.encode!(rpc(%{"error" => rpc_error(-32_603)}))
      discover = JSON.encode!(rpc(%{"result" => @discover}))

      table = [
        # {status, content-type, body, expected}
        {200, @json, discover, :modern},
        {200, "Application/JSON; charset=utf-8", discover, :modern},
        {400, @json, modern_400, {:modern_retry, "2026-07-28"}},
        {400, @json, legacy_400, :legacy},
        {400, nil, nil, :legacy},
        {400, "text/html", "<h1>Bad Request</h1>", :legacy},
        {404, "text/plain", "Not Found", :legacy},
        {404, @json, method_not_found, :legacy},
        {405, nil, "", :legacy},
        {400, @json, "{not json", :legacy},
        {400, @json, ~s({"hello":"world"}), :legacy},
        {200, @json, method_not_found, :legacy},
        {200, @json, internal, {:error, :protocol}},
        {401, @json, legacy_400, {:authorize, 401}},
        {403, nil, nil, {:authorize, 403}},
        {408, nil, nil, {:retry, {:http_status, 408}}},
        {429, nil, nil, {:retry, {:http_status, 429}}},
        {500, @json, legacy_400, {:retry, {:http_status, 500}}},
        {503, "text/html", "down", {:retry, {:http_status, 503}}},
        {202, nil, nil, {:error, :transport}},
        {302, nil, nil, {:error, :transport}},
        {406, "text/plain", "nope", {:error, :transport}}
      ]

      for {status, type, body, expected} <- table do
        verdict = Negotiation.classify_probe(:http, {:http, status, type, body})

        assert simplify(verdict) == expected,
               "#{status} #{inspect(type)} #{inspect(body)}: got #{inspect(verdict)}"
      end
    end

    test "network errors and timeouts retry, never downgrade" do
      assert Negotiation.classify_probe(:http, :timeout) == {:retry, :timeout}

      assert Negotiation.classify_probe(:http, {:transport_error, :econnrefused}) ==
               {:retry, :econnrefused}
    end

    test "an event-stream body is parsed for the response" do
      body =
        ": keep-alive\n\nevent: message\ndata: " <>
          JSON.encode!(rpc(%{"result" => @discover})) <> "\n\n"

      assert {:modern, "2026-07-28", _} =
               Negotiation.classify_probe(:http, {:http, 200, "text/event-stream", body})
    end

    test "an already decoded message is accepted" do
      assert {:modern_retry, "2026-07-28"} =
               Negotiation.classify_probe(
                 :http,
                 {:http, 400, nil,
                  rpc(%{"error" => rpc_error(-32_022, %{"supported" => ["2026-07-28"]})})}
               )
    end

    test "a modern error is never treated as legacy, whatever the status" do
      for status <- [400, 404, 405, 200] do
        assert {:error, %Error{reason: :missing_client_capability}} =
                 Negotiation.classify_probe(
                   :http,
                   {:http, status, @json, JSON.encode!(rpc(%{"error" => rpc_error(-32_021)}))}
                 )
      end
    end
  end

  defp simplify({:modern, _version, %DiscoverResult{}}), do: :modern
  defp simplify({:error, %Error{kind: kind}}), do: {:error, kind}
  defp simplify(other), do: other

  describe "client_capabilities/2 (SC-1)" do
    test "no handler, or one without input callbacks, advertises nothing" do
      assert Negotiation.client_capabilities(nil) == %{}
      assert Negotiation.client_capabilities(NoCallbacks) == %{}

      assert Negotiation.client_capabilities(NoCallbacks, era: :legacy, roots_list_changed: true) ==
               %{}
    end

    test "only implemented callbacks are advertised" do
      assert Negotiation.client_capabilities(Sampler) == %{"sampling" => %{}}
      assert Negotiation.client_capabilities(FormElicitor) == %{"elicitation" => %{"form" => %{}}}
    end

    test "all callbacks, with opt-in sub-capabilities" do
      caps =
        Negotiation.client_capabilities(Everything,
          sampling_tools: true,
          sampling_context: true,
          era: :legacy,
          roots_list_changed: true
        )

      assert caps == %{
               "sampling" => %{"tools" => %{}, "context" => %{}},
               "elicitation" => %{"form" => %{}, "url" => %{}},
               "roots" => %{"listChanged" => true}
             }

      assert :ok = McpSchema.validate("2025-11-25", "ClientCapabilities", caps)

      modern = Negotiation.client_capabilities(Everything, roots_list_changed: true)
      assert modern["roots"] == %{}
      assert :ok = McpSchema.validate("2026-07-28", "ClientCapabilities", modern)
    end

    test "bad elicitation modes or an unknown module raise at configuration time" do
      assert_raise ArgumentError, ~r/elicitation_modes/, fn ->
        Negotiation.client_capabilities(BadModes)
      end

      assert_raise ArgumentError, ~r/not an available module/, fn ->
        Negotiation.client_capabilities(:"Elixir.Does.Not.Exist")
      end
    end
  end
end
