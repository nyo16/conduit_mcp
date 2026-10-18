defmodule ConduitMcp.Client.Request.MRTRTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Request.MRTR
  alias ConduitMcp.Test.McpSchema

  @modern "2026-07-28"
  @all_caps %{"elicitation" => %{"form" => %{}, "url" => %{}}, "sampling" => %{}, "roots" => %{}}

  @params %{
    "name" => "deploy",
    "arguments" => %{"env" => "prod"},
    "_meta" => %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => @all_caps
    }
  }

  @complete %{
    "resultType" => "complete",
    "content" => [%{"type" => "text", "text" => "deployed"}]
  }

  @elicit %{
    "method" => "elicitation/create",
    "params" => %{
      "mode" => "form",
      "message" => "Confirm?",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"ok" => %{"type" => "boolean"}}
      }
    }
  }

  @sample %{
    "method" => "sampling/createMessage",
    "params" => %{
      "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}],
      "maxTokens" => 10
    }
  }

  @elicit_result %{"action" => "accept", "content" => %{"ok" => true}}
  @sample_result %{
    "role" => "assistant",
    "content" => %{"type" => "text", "text" => "hello"},
    "model" => "m"
  }

  # A scripted server: replies are popped in order and every send is
  # reported to the test process.
  defp run(responses, opts \\ [], method \\ "tools/call", params \\ @params) do
    Process.put(:mrtr_responses, responses)
    ids = :counters.new(1, [])
    test = self()

    defaults = [
      send: fn id, method, params ->
        send(test, {:sent, id, method, params})
        [reply | rest] = Process.get(:mrtr_responses)
        Process.put(:mrtr_responses, rest)
        reply
      end,
      next_id: fn ->
        :counters.add(ids, 1, 1)
        :counters.get(ids, 1)
      end,
      handle_input: fn key, request ->
        send(test, {:input, key, request})

        case request["method"] do
          "elicitation/create" -> {:ok, @elicit_result}
          "sampling/createMessage" -> {:ok, @sample_result}
          "roots/list" -> {:ok, %{"roots" => []}}
        end
      end,
      capabilities: @all_caps
    ]

    MRTR.run(method, params, Keyword.merge(defaults, opts))
  end

  defp input_required(fields), do: Map.put(fields, "resultType", "input_required")

  test "a complete result (or one with no resultType) ends after one round" do
    assert {:ok, @complete, %{rounds: 1}} = run([{:ok, @complete}])
    assert_received {:sent, 1, "tools/call", @params}

    legacy = Map.delete(@complete, "resultType")
    assert {:ok, ^legacy, %{rounds: 1}} = run([{:ok, legacy}])
  end

  test "golden: answers every input request, then retries with the same params, a new id and byte-exact state" do
    interim =
      input_required(%{
        "inputRequests" => %{"confirm" => @elicit, "draft" => @sample},
        "requestState" => "opaque+state/=="
      })

    assert :ok = McpSchema.validate(@modern, "InputRequiredResult", interim)
    assert :ok = McpSchema.validate(@modern, "CallToolResult", @complete)

    assert {:ok, @complete, %{rounds: 2}} = run([{:ok, interim}, {:ok, @complete}])

    assert_received {:sent, 1, "tools/call", @params}
    assert_received {:input, "confirm", @elicit}
    assert_received {:input, "draft", @sample}
    assert_received {:sent, 2, "tools/call", retry}

    assert retry ==
             Map.merge(@params, %{
               "inputResponses" => %{"confirm" => @elicit_result, "draft" => @sample_result},
               "requestState" => "opaque+state/=="
             })

    assert :ok = McpSchema.validate(@modern, "CallToolRequestParams", retry)
    assert :ok = McpSchema.validate(@modern, "ElicitResult", @elicit_result)
    assert :ok = McpSchema.validate(@modern, "CreateMessageResult", @sample_result)
  end

  test "MR-1: a 60 KiB state with base64 and unicode bytes is echoed byte-identically" do
    # 14 bytes per repeat: just under 60 KiB of valid UTF-8.
    state = String.duplicate("aZ+/=é✓\u{1F600}", 4_388)
    assert byte_size(state) > 60_000
    interim = input_required(%{"requestState" => state})

    assert {:ok, _, %{rounds: 2}} = run([{:ok, interim}, {:ok, @complete}])
    assert_received {:sent, 2, _, %{"requestState" => echoed} = retry}
    assert echoed === state
    refute Map.has_key?(retry, "inputResponses")
    refute_received {:input, _, _}
  end

  test "absent requestState is omitted on the retry, and state never carries into a later round" do
    first =
      input_required(%{
        "inputRequests" => %{"r" => %{"method" => "roots/list"}},
        "requestState" => "s1"
      })

    second = input_required(%{"inputRequests" => %{"r" => %{"method" => "roots/list"}}})

    assert {:ok, _, %{rounds: 3}} = run([{:ok, first}, {:ok, second}, {:ok, @complete}])

    assert_received {:sent, 2, _, %{"requestState" => "s1"}}
    assert_received {:sent, 3, _, third}
    refute Map.has_key?(third, "requestState")
    assert third["inputResponses"] == %{"r" => %{"roots" => []}}
  end

  test "caller-supplied inputResponses or requestState are not sent on the first round" do
    stale = Map.merge(@params, %{"inputResponses" => %{"x" => %{}}, "requestState" => "old"})
    assert {:ok, _, _} = run([{:ok, @complete}], [], "tools/call", stale)
    assert_received {:sent, 1, _, @params}
  end

  describe "MR-4 limits" do
    test "the round limit trips after max_rounds sends" do
      interim = input_required(%{"requestState" => "s"})

      assert {:error, %Error{kind: :mrtr_round_limit, reason: :max_rounds}} =
               run(List.duplicate({:ok, interim}, 8))

      for id <- 1..8, do: assert_received({:sent, ^id, _, _})
      refute_received {:sent, _, _, _}

      assert {:error, %Error{kind: :mrtr_round_limit, data: %{limit: 2}}} =
               run(List.duplicate({:ok, interim}, 2), max_rounds: 2)
    end

    test "more than 16 input requests fail before any handler runs" do
      requests = Map.new(1..17, &{"k#{&1}", %{"method" => "roots/list"}})

      assert {:error, %Error{kind: :mrtr_round_limit, reason: :max_input_requests}} =
               run([{:ok, input_required(%{"inputRequests" => requests})}])

      refute_received {:input, _, _}

      sixteen = Map.new(1..16, &{"k#{&1}", %{"method" => "roots/list"}})

      assert {:ok, _, %{rounds: 2}} =
               run([{:ok, input_required(%{"inputRequests" => sixteen})}, {:ok, @complete}])
    end

    test "a requestState over 64 KiB fails without being retried or exposed" do
      state = String.duplicate("s", 64 * 1024 + 1)

      assert {:error, %Error{kind: :mrtr_round_limit, reason: :max_request_state_bytes} = error} =
               run([{:ok, input_required(%{"requestState" => state})}])

      refute inspect(error) =~ "sss"
      assert_received {:sent, 1, _, _}
      refute_received {:sent, 2, _, _}
    end
  end

  describe "input requests" do
    test "SC-1: an undeclared capability fails the call and no handler runs" do
      interim =
        input_required(%{
          "inputRequests" => %{"a" => @elicit, "b" => @sample},
          "requestState" => "s"
        })

      assert {:error, %Error{kind: :protocol, reason: {:undeclared_input_request, method}}} =
               run([{:ok, interim}], capabilities: %{"elicitation" => %{}})

      assert method == "sampling/createMessage"
      refute_received {:input, _, _}

      assert {:error, %Error{kind: :protocol}} = run([{:ok, interim}], capabilities: %{})
      refute_received {:input, _, _}
    end

    test "elicitation modes must be declared; an empty capability means form" do
      url = %{
        "method" => "elicitation/create",
        "params" => %{"mode" => "url", "url" => "https://x", "message" => "m"}
      }

      assert {:error, %Error{reason: {:undeclared_elicitation_mode, "url"}}} =
               run([{:ok, input_required(%{"inputRequests" => %{"u" => url}})}],
                 capabilities: %{"elicitation" => %{"form" => %{}}}
               )

      assert {:ok, _, _} =
               run(
                 [
                   {:ok, input_required(%{"inputRequests" => %{"f" => @elicit}})},
                   {:ok, @complete}
                 ],
                 capabilities: %{"elicitation" => %{}}
               )
    end

    test "unknown or malformed input requests are protocol errors" do
      for request <- [%{"method" => "tools/list"}, %{"params" => %{}}, "junk"] do
        assert {:error, %Error{kind: :protocol}} =
                 run([{:ok, input_required(%{"inputRequests" => %{"x" => request}})}])
      end

      refute_received {:input, _, _}
    end

    test "handler failures abort with :input_handler and the caller survives" do
      interim = input_required(%{"inputRequests" => %{"e" => @elicit}})

      failures = [
        {fn _, _ -> raise "boom" end, {:raised, "e"}},
        {fn _, _ -> throw(:oops) end, {:raised, "e"}},
        {fn _, _ -> exit(:bye) end, {:raised, "e"}},
        {fn _, _ -> {:error, :user_busy} end, {:handler_error, "e"}},
        {fn _, _ -> {:ok, "not a map"} end, {:invalid_response, "e"}},
        {fn _, _ -> :whatever end, {:invalid_response, "e"}}
      ]

      for {handler, reason} <- failures do
        assert {:error, %Error{kind: :input_handler, reason: ^reason}} =
                 run([{:ok, interim}], handle_input: handler)
      end
    end
  end

  describe "result types" do
    test "an unknown resultType is invalid unless explicitly accepted" do
      task = %{"resultType" => "task", "task" => %{"taskId" => "t1"}}

      assert {:error, %Error{kind: :protocol, reason: {:unknown_result_type, "task"}}} =
               run([{:ok, task}])

      assert {:ok, ^task, %{rounds: 1}} = run([{:ok, task}], result_types: ["task"])

      assert {:error, %Error{reason: :invalid_result_type}} = run([{:ok, %{"resultType" => 1}}])
      assert {:error, %Error{reason: :invalid_result}} = run([{:ok, [1, 2]}])
    end

    test "input_required on a method that cannot use MRTR is a protocol error" do
      interim = input_required(%{"requestState" => "s"})

      assert {:error, %Error{reason: {:input_required_not_allowed, "tools/list"}}} =
               run([{:ok, interim}], [], "tools/list", %{})

      for method <- ["resources/read", "prompts/get"] do
        assert {:ok, _, %{rounds: 2}} = run([{:ok, interim}, {:ok, @complete}], [], method, %{})
      end
    end

    test "an input_required with neither inputRequests nor requestState is invalid" do
      assert {:error, %Error{reason: :empty_input_required}} = run([{:ok, input_required(%{})}])

      assert {:error, %Error{reason: :invalid_input_required}} =
               run([{:ok, input_required(%{"requestState" => 5})}])
    end
  end

  test "a send error is returned unchanged" do
    error = Error.new(:timeout, :deadline)
    assert {:error, ^error} = run([{:error, error}])
  end

  test "missing injected functions raise" do
    assert_raise ArgumentError, ~r/:send/, fn -> MRTR.run("tools/call", %{}, []) end

    assert_raise ArgumentError, ~r/:max_rounds/, fn ->
      run([], max_rounds: 0)
    end
  end

  # The global atom count is unusable under `async: true`, so the property
  # checks that no atom named after any server-chosen string exists after
  # the loop has handled it.
  property "server-chosen keys, methods and result types never become atoms" do
    check all(suffix <- StreamData.string(:alphanumeric, min_length: 8, max_length: 16)) do
      names = for tag <- ~w(key method type state), do: "mrtr_probe_#{tag}_#{suffix}"
      [key, method, type, state] = names

      run([
        {:ok,
         input_required(%{
           "inputRequests" => %{key => %{"method" => "roots/list"}},
           "requestState" => state
         })},
        {:ok, @complete}
      ])

      run([{:ok, input_required(%{"inputRequests" => %{key => %{"method" => method}}})}])
      run([{:ok, %{"resultType" => type}}])

      for name <- names, do: refute(atom_exists?(name), "#{name} became an atom")
    end
  end

  defp atom_exists?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
