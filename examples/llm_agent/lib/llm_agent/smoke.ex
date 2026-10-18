defmodule LlmAgent.Smoke do
  @moduledoc """
  Exercises everything but the model: waits for both servers, lists the
  hub's tools in Anthropic's format, then runs a synthetic `tool_use`
  response through `ConduitMcp.Client.Adapters.execute_tool_calls/4` and
  checks the policy, the hooks and the routing. Needs no API key.
  """

  alias LlmAgent.Agent

  @response %{
    "role" => "assistant",
    "stop_reason" => "tool_use",
    "content" => [
      %{"type" => "text", "text" => "Let me look."},
      %{
        "type" => "tool_use",
        "id" => "toolu_read",
        "name" => "notes__read_note",
        "input" => %{"id" => "deploy"}
      },
      %{
        "type" => "tool_use",
        "id" => "toolu_reverse",
        "name" => "tools__reverse_string",
        "input" => %{"text" => "conduit"}
      },
      %{
        "type" => "tool_use",
        "id" => "toolu_delete",
        "name" => "notes__delete_note",
        "input" => %{"id" => "deploy"}
      },
      %{
        "type" => "tool_use",
        "id" => "toolu_unknown",
        "name" => "shell__exec",
        "input" => %{"cmd" => "rm -rf /"}
      }
    ]
  }

  @doc "Runs the checks; raises on the first that fails."
  @spec run() :: :ok
  def run do
    status =
      case Agent.await_servers() do
        {:ok, status} -> status
        {:error, status} -> raise "servers not ready: #{inspect(status)}"
      end

    for server <- status, do: IO.puts("server #{server.id}: #{server.state} (#{server.era})")

    {:ok, listing} = ConduitMcp.Client.Adapters.tools(LlmAgent.Hub, :anthropic)
    names = Enum.map(listing.tools, & &1["name"])
    IO.puts("tools offered to the model: #{Enum.join(names, ", ")}")

    expected =
      ~w(notes__list_notes notes__read_note notes__delete_note tools__echo tools__reverse_string)

    check(Enum.sort(names) == Enum.sort(expected), "tool list #{inspect(names)}")

    {:ok, results, taint} =
      Agent.run_tools(@response, listing, MapSet.new(), %{principal: "smoke"})

    by_id = Map.new(results, &{&1["tool_use_id"], &1})

    for result <- results do
      IO.puts("#{result["tool_use_id"]} is_error=#{result["is_error"]}: #{text(result)}")
    end

    read = by_id["toolu_read"]
    check(not read["is_error"] and text(read) =~ "[REDACTED]", "read_note was redacted")
    check(not (text(read) =~ "sk-demo"), "no secret reached the model")

    check(text(by_id["toolu_reverse"]) == "tiudnoc", "reverse_string over HTTP")
    check(by_id["toolu_delete"]["is_error"], "delete_note denied by policy")
    check(by_id["toolu_unknown"]["is_error"], "unknown tool answered without a call")
    check(MapSet.equal?(taint, MapSet.new(["notes", "tools"])), "taint #{inspect(taint)}")

    IO.puts("\nsmoke: OK")
  end

  defp text(%{"content" => blocks}), do: Enum.map_join(blocks, "", &(&1["text"] || ""))

  defp check(true, _what), do: :ok
  defp check(_false, what), do: raise("smoke check failed: #{what}")
end
