defmodule ConduitMcp.Client.ConfigTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Transport.InProcess

  doctest ConduitMcp.Client.Config
  doctest ConduitMcp.Client.Backoff
  doctest ConduitMcp.Client
  doctest ConduitMcp.Client.Request

  defmodule HttpKind do
    def kind, do: :http
    def init(_opts, _ctx), do: {:ok, nil}
  end

  @transport {InProcess, server: ConduitMcp.TestServer}

  defp new!(opts), do: Config.new!(Keyword.merge([name: :cfg, transport: @transport], opts))

  describe "defaults" do
    test "match the documented security defaults" do
      config = new!([])

      assert %Config{
               protocol: :auto,
               prior: nil,
               handler: nil,
               request_timeout: 60_000,
               max_in_flight: 64,
               max_reconnects: :infinity,
               on_give_up: :stay,
               stable_after: 30_000,
               health_check_interval: nil
             } = config

      assert %{"name" => "conduit_mcp", "version" => version} = config.client_info
      assert is_binary(version)
      assert config.backoff.(1) in 1..1_000

      assert Map.new(config.sampling) == %{
               max_tokens: 4_096,
               context: false,
               tools: false,
               allow_idle: false,
               rejection_code: -1
             }

      assert Map.new(config.handler_timeout) ==
               %{sampling: 60_000, elicitation: 300_000, roots: 60_000}

      assert config.max_server_requests == 8
      assert Map.new(config.input_rate_limit) == %{per_second: 10, burst: 20}
      assert config.max_cache_ttl == 3_600_000
      assert config.assigns == %{}
    end

    test "probe_timeout follows the transport kind unless set" do
      assert new!([]).probe_timeout == 3_000
      assert new!(transport: {HttpKind, []}).probe_timeout == 5_000
      assert new!(transport: {HttpKind, []}, probe_timeout: 10).probe_timeout == 10
    end

    test "server_id is the name when it is a string, else its inspect" do
      assert new!(name: "github").server_id == "github"
      assert new!(name: {:tenant, 7}).server_id == "{:tenant, 7}"
      assert new!(name: :x, server_id: "files").server_id == "files"
    end
  end

  describe "invalid options raise naming the key" do
    for {opts, key} <- [
          {[max_in_flight: 0], ":max_in_flight"},
          {[protocol: "2024-11-05"], ":protocol"},
          {[protocol: :newest], ":protocol"},
          {[prior: :maybe], ":prior"},
          {[on_give_up: :retry], ":on_give_up"},
          {[transport: {ConduitMcp.TestServer, []}], ":transport"},
          {[transport: {InProcess, :not_a_keyword}], ":transport"},
          {[handler: "MyHandler"], ":handler"},
          {[client_info: %{"name" => "x"}], ":client_info"},
          {[backoff: &System.monotonic_time/0], ":backoff"},
          {[sampling: [max_tokens: 0]], ":max_tokens"},
          {[handler_timeout: [elicitation: :forever]], ":elicitation"},
          {[elicitation: [origin: 1]], ":origin"},
          {[surprise: true], ":surprise"},
          {[policy: [deny: :all]], "policy :deny"},
          {[policy: "allow everything"], ":policy"},
          {[on_ask: &Kernel.length/1], ":on_ask"},
          {[hooks: [pre_tool_call: [{:all, &Kernel.length/1}]]], ":hooks"},
          {[tools: [include: "*"]], ":tools"},
          {[validate: [arguments: :yes]], ":arguments"},
          {[approved_fingerprints: %{read: "x"}], ":approved_fingerprints"},
          {[hook_timeout: 0], ":hook_timeout"}
        ] do
      @opts opts
      @key key

      test "#{inspect(opts)}" do
        error = assert_raise ArgumentError, fn -> new!(@opts) end
        assert error.message =~ @key
      end
    end

    test "a missing name or transport" do
      assert_raise ArgumentError, ~r/:name/, fn -> Config.new!(transport: @transport) end
      assert_raise ArgumentError, ~r/:transport/, fn -> Config.new!(name: :x) end
    end

    test "a custom validator must implement ConduitMcp.Client.SchemaValidator" do
      assert_raise ArgumentError, ~r/:validator ConduitMcp.TestServer does not implement/, fn ->
        new!(validate: [arguments: true, validator: ConduitMcp.TestServer])
      end

      # Not checked when nothing is validated.
      assert %{validate: nil} = new!(validate: [validator: ConduitMcp.TestServer]).governance
    end

    test "governance options are compiled when validated" do
      config =
        new!(
          policy: [allow: ["*"]],
          tools: [exclude: ["x"]],
          hooks: [pre_tool_call: [{:all, fn _call, _ctx -> :cont end}]],
          validate: [structured_content: true]
        )

      governance = config.governance
      assert governance.enabled?
      assert %ConduitMcp.Client.Policy{} = governance.policy
      assert %ConduitMcp.Client.ToolFilter{} = governance.filter
      assert [_hook] = governance.hooks.pre_tool_call

      assert governance.validate == %{
               arguments: false,
               structured_content: true,
               validator: ConduitMcp.Client.SchemaValidator.JSV
             }

      plain = new!([]).governance
      refute plain.enabled?
      assert %ConduitMcp.Client.Hooks{pre_tool_call: []} = plain.hooks
      assert plain.validate == nil
    end

    test "child_spec/1 validates, so a typo fails when the tree is built" do
      assert_raise ArgumentError, ~r/:max_inflight/, fn ->
        Client.child_spec(name: :x, transport: @transport, max_inflight: 1)
      end
    end
  end

  test "the moduledoc documents every option" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Config)

    for key <- ~w(name transport protocol probe_timeout prior handler client_info
                  request_timeout max_total_timeout max_in_flight max_queued backoff
                  max_reconnects on_give_up stable_after health_check_interval assigns
                  handler_timeout max_server_requests input_rate_limit sampling
                  elicitation roots max_cache_ttl policy on_ask ask_timeout grant_ttl
                  approved_fingerprints hooks hook_timeout tools validate trusted
                  max_result_bytes_for_llm include_instructions clock) do
      assert doc =~ "`:#{key}`", key
    end
  end
end
