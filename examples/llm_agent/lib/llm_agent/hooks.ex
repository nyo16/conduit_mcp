defmodule LlmAgent.Hooks do
  @moduledoc """
  The hub's hooks (`ConduitMcp.Client.Hooks`).

  Hooks cannot allow a call - the policy is the only allow authority - but a
  pre-hook sees every call before the policy runs, and a post-hook sees
  every result before it reaches the model.
  """

  require Logger

  alias ConduitMcp.Client.{ToolCall, ToolResult}

  # Anthropic-style and generic `sk-` secrets, bearer tokens.
  @secret ~r/\b(sk-[A-Za-z0-9_-]{8,}|Bearer\s+[A-Za-z0-9._~+\/-]{8,})/

  @doc "Pre-hook: an audit line per call (its arguments digest, never the arguments)."
  @spec audit(ToolCall.t(), map()) :: :cont
  def audit(%ToolCall{} = call, ctx) do
    Logger.info(
      "audit: #{call.server_id}/#{call.name} call_id=#{call.call_id} " <>
        "args_digest=#{call.args_digest} principal=#{inspect(ctx.principal)}"
    )

    :cont
  end

  @doc "Post-hook: replaces anything that looks like a secret in text content."
  @spec redact(ToolCall.t(), ToolResult.t(), map()) :: :cont | {:cont, ToolResult.t()}
  def redact(%ToolCall{}, %ToolResult{content: content} = result, _ctx) do
    redacted = Enum.map(content, &redact_block/1)

    if redacted == content,
      do: :cont,
      else: {:cont, %{result | content: redacted}}
  end

  defp redact_block(%{"type" => "text", "text" => text} = block),
    do: %{block | "text" => Regex.replace(@secret, text, "[REDACTED]")}

  defp redact_block(block), do: block
end
