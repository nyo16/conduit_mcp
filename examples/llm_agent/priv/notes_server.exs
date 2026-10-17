# A tiny MCP server on stdio: the "notes" server of the llm_agent example.
#
# LlmAgent.Servers starts it as
#
#     elixir -pa <every _build/<env>/lib/*/ebin> priv/notes_server.exs
#
# so it loads ConduitMcp from this project's build. It reads
# newline-delimited JSON-RPC from stdin, runs each message through
# ConduitMcp.Handler.dispatch/3 (which serves both protocol eras, as the HTTP
# transports do) and writes one JSON line per reply. stdout carries the
# protocol, so logs go to stderr.

defmodule LlmAgent.NotesServer do
  use ConduitMcp.Server

  @notes %{
    "deploy" => """
    Deploy checklist: run migrations, then roll the web nodes one at a time.
    Staging API key (rotate after the demo): sk-demo-4f9a2c7e1b3d5f6a
    """,
    "groceries" => "Coffee beans, oat milk, lemons."
  }

  tool "list_notes", "Lists the ids of the saved notes" do
    annotations read_only: true

    handle fn _conn, _params ->
      json(%{"notes" => @notes |> Map.keys() |> Enum.sort()})
    end
  end

  tool "read_note", "Returns the text of one note" do
    param :id, :string, "The note id (see list_notes)", required: true
    annotations read_only: true

    handle fn _conn, %{"id" => id} ->
      case Map.fetch(@notes, id) do
        {:ok, note} -> text(note)
        :error -> error("no note named #{inspect(id)}")
      end
    end
  end

  tool "delete_note", "Deletes a note" do
    param :id, :string, "The note id", required: true
    annotations destructive: true

    handle fn _conn, %{"id" => id} ->
      text("deleted #{id}")
    end
  end
end

defmodule LlmAgent.NotesServer.Stdio do
  alias ConduitMcp.{Handler, Notifications, StreamSpec}

  @subscription_id "io.modelcontextprotocol/subscriptionId"

  def main do
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:stderr, :logger_std_h, %{
        level: :warning,
        config: %{type: :standard_error}
      })

    {:ok, _apps} = Application.ensure_all_started(:conduit_mcp)
    :ok = :io.setopts(:standard_io, binary: true)

    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      private: %{
        server_module: LlmAgent.NotesServer,
        server_name: "notes",
        server_version: "0.1.0",
        instructions: nil
      }
    }

    loop(conn)
  end

  defp loop(conn) do
    case IO.binread(:stdio, :line) do
      :eof -> System.halt(0)
      {:error, _reason} -> System.halt(1)
      line -> line |> String.trim_trailing() |> handle(conn) |> loop()
    end
  end

  defp handle("", conn), do: conn

  defp handle(line, conn) do
    case Handler.dispatch(JSON.decode!(line), LlmAgent.NotesServer, conn) do
      {:reply, response} -> write(response)
      # This server publishes no notifications: acknowledge the listen and
      # never write to it again.
      {:stream, %StreamSpec{kind: :listen} = spec} -> acknowledge(spec)
      {:stream, spec} -> write(StreamSpec.run(spec))
      :noreply -> :ok
    end

    conn
  end

  defp acknowledge(%StreamSpec{request_id: id, subscription: filter}) do
    ack = Notifications.subscriptions_acknowledged_notification(filter.ack)
    params = Map.get(ack, "params") || %{}
    meta = Map.put(Map.get(params, "_meta") || %{}, @subscription_id, id)
    write(Map.put(ack, "params", Map.put(params, "_meta", meta)))
  end

  defp write(message), do: IO.binwrite(:stdio, [JSON.encode!(message), ?\n])
end

LlmAgent.NotesServer.Stdio.main()
