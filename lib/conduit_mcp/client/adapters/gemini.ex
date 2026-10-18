defmodule ConduitMcp.Client.Adapters.Gemini do
  @moduledoc """
  Converts between a `ConduitMcp.Client.ToolSet` and Gemini API
  (`generateContent`) function calling. Pure functions over string-keyed
  maps; no HTTP.

  > #### Experimental {: .warning}
  >
  > This adapter is experimental: its shapes come from the Gemini API
  > reference, not from end-to-end runs against the API, and may change in
  > a minor release.

      {toolset, _} = ConduitMcp.Client.Naming.build([{"files", tools}])
      request = %{"contents" => contents,
                  "tools" => [%{"functionDeclarations" => Gemini.function_declarations(toolset)}]}

      {calls, rejected} = Gemini.function_calls(response, toolset)
      # run each %ToolCall{} through the client pipeline (or let
      # ConduitMcp.Client.Adapters.execute_tool_calls/4 do all of this), then:
      parts = Enum.map(outcomes, fn {call, outcome} ->
        {:ok, name} = ConduitMcp.Client.ToolSet.exposed_name(toolset, call.server_id, call.name)
        Gemini.function_response(name, outcome, id: call.call_id)
      end)
      # next turn: %{"role" => "user", "parts" => rejected ++ parts}

  ## Verified rules (2026-10-17)

  From the `FunctionDeclaration`, `FunctionCall` and `FunctionResponse`
  reference at https://ai.google.dev/api/generate-content and the guide at
  https://ai.google.dev/gemini-api/docs/function-calling:

    * `FunctionDeclaration.name` may contain `a-z A-Z 0-9 _ : . -`, at most
      128 characters. The toolset's exposed names (`^[A-Za-z0-9_-]{1,64}$`)
      are a subset.
    * `parametersJsonSchema` takes the parameters as JSON Schema (an object
      schema); `parameters` takes the OpenAPI 3.0 `Schema` subset instead.
      The two are mutually exclusive. This adapter sends the MCP
      `inputSchema` unchanged as `parametersJsonSchema`.
    * `description` is required, so a tool without one gets `""`.
    * `FunctionCall` is `{id?, name, args?}`; `FunctionResponse` is
      `{id?, name, response}` where `response` must be a JSON object. By the
      reference's convention the output goes under `"output"` and a failure
      under `"error"`.

  ## Results

  `function_response/3` puts the result under `response.output`: the
  `structuredContent` object when present (default `structured: :prefer`),
  otherwise the content as text, with media as placeholders such as
  `"[image: image/png, 1024 bytes]"`. A result with `is_error: true`, or a
  `ConduitMcp.Client.Error`, goes under `response.error` as text.
  Descriptions have invisible characters removed and are capped at 4 KiB
  (PI-1); only tools in the toolset are emitted (PO-7).
  """

  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.{Error, ToolCall, ToolResult, ToolSet}

  @doc """
  The `functionDeclarations` for `toolset`, in toolset order. Wrap them as
  `%{"functionDeclarations" => declarations}` in the request's `tools`.
  """
  @spec function_declarations(ToolSet.t()) :: [map()]
  def function_declarations(%ToolSet{} = toolset) do
    for {name, tool} <- ToolSet.entries(toolset) do
      %{
        "name" => name,
        "description" => Content.description(tool.description) || "",
        "parametersJsonSchema" => tool.input_schema
      }
    end
  end

  @doc """
  Extracts the function calls from a response.

  Accepts a `generateContent` response (the first candidate's content is
  used), a `Content` (`"parts"`), or a list of parts. Each `functionCall`
  part whose `name` resolves in `toolset` becomes a
  `ConduitMcp.Client.ToolCall` with `call_id` set to the call's `id` (which
  Gemini may omit, giving `nil`).

  A call naming a tool not in the toolset, or with `args` that are not an
  object, produces no call (HB-2). Instead it yields a `functionResponse`
  part with an `"error"`, returned in the second list, to send back to the
  model. Other parts are ignored.
  """
  @spec function_calls(map() | [map()], ToolSet.t()) :: {[ToolCall.t()], [map()]}
  def function_calls(response, %ToolSet{} = toolset),
    do: response |> __function_calls__(toolset) |> Content.split_calls()

  @doc false
  # `function_calls/2` in the model's order, one `{:call, %ToolCall{}}` or
  # `{:rejected, part}` per `functionCall` part, for
  # `ConduitMcp.Client.Adapters.execute_tool_calls/4`.
  @spec __function_calls__(map() | [map()], ToolSet.t()) :: [Content.parsed()]
  def __function_calls__(%{"candidates" => [%{"content" => content} | _]}, toolset),
    do: __function_calls__(content, toolset)

  def __function_calls__(%{"candidates" => _}, _toolset), do: []

  def __function_calls__(%{"parts" => parts}, toolset) when is_list(parts),
    do: __function_calls__(parts, toolset)

  def __function_calls__(%{} = _content, _toolset), do: []

  def __function_calls__(parts, %ToolSet{} = toolset) when is_list(parts) do
    for %{"functionCall" => %{} = call} <- parts do
      case to_call(call, toolset) do
        {:ok, tool_call} -> {:call, tool_call}
        {:error, text} -> {:rejected, error_part(call, text)}
      end
    end
  end

  defp to_call(call, toolset) do
    with {:ok, tool} <- resolve(toolset, call["name"]),
         {:ok, args} <- args(call) do
      {:ok, ToolCall.new(tool.server_id, tool.name, args, call_id: call["id"])}
    end
  end

  defp resolve(toolset, name) do
    case ToolSet.resolve(toolset, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, Content.unknown_tool_text(name)}
    end
  end

  defp args(%{"args" => args}) when is_map(args), do: {:ok, args}
  defp args(%{"args" => nil}), do: {:ok, %{}}
  defp args(call) when not is_map_key(call, "args"), do: {:ok, %{}}
  defp args(_call), do: {:error, Content.invalid_arguments_text()}

  defp error_part(call, text) do
    name = if is_binary(call["name"]), do: call["name"], else: ""
    response_part(name, %{"error" => text}, call["id"])
  end

  @doc """
  Builds the `functionResponse` part answering a call to `name` (the
  exposed name the model used).

  ## Options

    * `:id` - the `functionCall.id` being answered, when Gemini sent one.
    * `:structured` - `:prefer` (default) sends `structuredContent` itself
      as `output` when present; `:auto`, `:append` and `:ignore` render the
      content as text, handling `structuredContent` as described in
      `ConduitMcp.Client.Adapters.OpenAI.tool_output/3`.
  """
  @spec function_response(String.t(), ToolResult.t() | Error.t(), keyword()) :: map()
  def function_response(name, result, opts \\ []) do
    response_part(name, response(result, Keyword.get(opts, :structured, :prefer)), opts[:id])
  end

  defp response(%ToolResult{is_error: false, structured: structured}, :prefer)
       when not is_nil(structured),
       do: %{"output" => structured}

  # Errors (and results without structuredContent) under `:prefer` render
  # their content as text, like `:auto`.
  defp response(result, :prefer), do: response(result, :auto)

  defp response(result, structured_mode) do
    case Content.parts(result, structured: structured_mode) do
      {true, parts} -> %{"error" => Content.to_text(parts)}
      {false, parts} -> %{"output" => Content.to_text(parts)}
    end
  end

  defp response_part(name, response, nil),
    do: %{"functionResponse" => %{"name" => name, "response" => response}}

  defp response_part(name, response, id),
    do: %{"functionResponse" => %{"id" => id, "name" => name, "response" => response}}
end
