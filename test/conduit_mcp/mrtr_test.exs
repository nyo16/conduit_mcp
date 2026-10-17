defmodule ConduitMcp.MRTRTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.MRTR
  alias ConduitMcp.Test.McpSchema

  doctest ConduitMcp.MRTR, only: [missing_capabilities: 2]

  @schema %{
    "type" => "object",
    "properties" => %{"api_key" => %{"type" => "string", "title" => "API Key"}},
    "required" => ["api_key"]
  }

  # The deprecated builders are exercised through a runtime module reference so
  # the deprecation warning (the point of `@deprecated`) does not fail
  # `--warnings-as-errors` here.
  defp deprecated, do: Function.identity(MRTR)

  defp assert_input_request(def_name, request) do
    assert :ok == McpSchema.validate("2026-07-28", def_name, request)
    assert :ok == McpSchema.validate("2026-07-28", "InputRequest", request)
    assert :ok == McpSchema.validate("2026-07-28", "InputRequests", %{"k" => request})
    refute Map.has_key?(request, "jsonrpc")
    refute Map.has_key?(request, "id")
  end

  test "elicit/2 builds a form-mode elicitation input request" do
    request = MRTR.elicit("Please provide your API key", @schema)

    assert request == %{
             "method" => "elicitation/create",
             "params" => %{
               "message" => "Please provide your API key",
               "requestedSchema" => @schema
             }
           }

    assert_input_request("ElicitRequest", request)
  end

  test "sample/2 builds a sampling input request with only the set options" do
    messages = [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}]
    request = deprecated().sample(messages, max_tokens: 1000, system_prompt: "Be brief")

    assert request == %{
             "method" => "sampling/createMessage",
             "params" => %{
               "messages" => messages,
               "maxTokens" => 1000,
               "systemPrompt" => "Be brief"
             }
           }

    assert_input_request("CreateMessageRequest", request)
  end

  test "sample/2 requires :max_tokens, as the spec does" do
    assert_raise KeyError, fn -> deprecated().sample([], []) end
  end

  test "list_roots/0 builds a roots input request" do
    request = deprecated().list_roots()
    assert request == %{"method" => "roots/list"}
    assert_input_request("ListRootsRequest", request)
  end

  describe "missing_capabilities/2" do
    @form MRTR.elicit("Approve?", %{"type" => "object"})
    @url %{
      "method" => "elicitation/create",
      "params" => %{
        "mode" => "url",
        "message" => "m",
        "url" => "https://x",
        "elicitationId" => "e"
      }
    }

    test "a bare elicitation declares form mode only" do
      assert MRTR.missing_capabilities(%{"a" => @form}, %{"elicitation" => %{}}) == %{}

      assert MRTR.missing_capabilities(%{"a" => @url}, %{"elicitation" => %{}}) ==
               %{"elicitation" => %{"url" => %{}}}

      assert MRTR.missing_capabilities(%{"a" => @form}, %{"elicitation" => %{"url" => %{}}}) ==
               %{"elicitation" => %{"form" => %{}}}
    end

    test "sampling needs its tools and context sub-capabilities when used" do
      sample = fn params ->
        %{
          "method" => "sampling/createMessage",
          "params" => Map.merge(%{"maxTokens" => 1}, params)
        }
      end

      requests = %{
        "plain" => sample.(%{}),
        "tools" => sample.(%{"tools" => []}),
        "ctx" => sample.(%{"includeContext" => "thisServer"})
      }

      assert MRTR.missing_capabilities(requests, %{}) ==
               %{"sampling" => %{"tools" => %{}, "context" => %{}}}

      assert MRTR.missing_capabilities(requests, %{"sampling" => %{"tools" => %{}}}) ==
               %{"sampling" => %{"context" => %{}}}

      assert MRTR.missing_capabilities(%{"p" => sample.(%{"includeContext" => "none"})}, %{
               "sampling" => %{}
             }) == %{}
    end

    test "missing requirements merge into one ClientCapabilities map" do
      requests = %{"a" => @form, "b" => %{"method" => "roots/list"}}
      missing = MRTR.missing_capabilities(requests, %{"roots" => true})

      assert missing == %{"elicitation" => %{"form" => %{}}, "roots" => %{}}
      assert :ok == McpSchema.validate("2026-07-28", "ClientCapabilities", missing)
    end
  end
end
