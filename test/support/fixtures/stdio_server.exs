# An MCP server on stdio, for the tests of ConduitMcp.Client.Transport.Stdio.
# ConduitMcp.Test.Client.StdioFixture starts it as
#
#     elixir -pa <every _build/test/lib/*/ebin> stdio_server.exs [MODE] [--server MODULE]
#
# It reads newline-delimited JSON-RPC from stdin and runs each message
# through ConduitMcp.Handler.dispatch/3 - which classifies its era with
# ConduitMcp.Era.classify/2, exactly as the HTTP transports do - against the
# server module (default ConduitMcp.TestServer), writing one JSON line per
# reply. It starts the :conduit_mcp application (the handler uses its ETS
# tables) with a random :mrtr_keys keyring, so a server may answer
# `{:input_required, ...}`.
#
# MODE:
#
#   normal                 serve until stdin closes, then exit 0
#   exit_after:N           exit with status 3 after answering N requests
#   garbage_stdout[:N]     write N (default 1) non-JSON lines before every reply
#   ignore_eof             keep running after stdin closes (until signalled)
#   never_answer_discover  never answer server/discover (a silent legacy server)
#   slow:MS                wait MS milliseconds before every reply
#   huge_line              answer tools/call with 20 MB and no newline

defmodule ConduitMcp.Test.StdioServerScript do
  alias ConduitMcp.Handler
  alias ConduitMcp.StreamSpec

  def main(argv) do
    # stdout carries the protocol: logs go to stderr.
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:stderr, :logger_std_h, %{
        level: :warning,
        config: %{type: :standard_error}
      })

    Application.put_env(:conduit_mcp, :mrtr_keys, [{"fixture", :crypto.strong_rand_bytes(32)}])
    {:ok, _apps} = Application.ensure_all_started(:conduit_mcp)

    {switches, rest} = OptionParser.parse!(argv, strict: [server: :string])
    server = Module.concat([switches[:server] || "ConduitMcp.TestServer"])
    {:module, ^server} = Code.ensure_loaded(server)

    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      private: %{
        server_module: server,
        server_name: nil,
        server_version: nil,
        instructions: nil
      }
    }

    :ok = :io.setopts(:standard_io, binary: true)

    loop(%{
      mode: parse_mode(List.first(rest) || "normal"),
      server: server,
      conn: conn,
      answered: 0
    })
  end

  defp parse_mode(mode) do
    case String.split(mode, ":", parts: 2) do
      ["exit_after", n] -> {:exit_after, String.to_integer(n)}
      ["garbage_stdout"] -> {:garbage_stdout, 1}
      ["garbage_stdout", n] -> {:garbage_stdout, String.to_integer(n)}
      ["slow", ms] -> {:slow, String.to_integer(ms)}
      ["normal"] -> :normal
      ["ignore_eof"] -> :ignore_eof
      ["never_answer_discover"] -> :never_answer_discover
      ["huge_line"] -> :huge_line
    end
  end

  defp loop(state) do
    case IO.binread(:stdio, :line) do
      :eof -> eof(state.mode)
      {:error, _reason} -> System.halt(1)
      line -> line |> String.trim_trailing() |> handle(state) |> loop()
    end
  end

  defp eof(:ignore_eof), do: Process.sleep(:infinity)
  defp eof(_mode), do: System.halt(0)

  defp handle("", state), do: state

  defp handle(line, state) do
    message = JSON.decode!(line)

    cond do
      state.mode == :never_answer_discover and message["method"] == "server/discover" ->
        state

      state.mode == :huge_line and message["method"] == "tools/call" ->
        IO.binwrite(:stdio, :binary.copy("x", 20_000_000))
        state

      true ->
        case Handler.dispatch(message, state.server, state.conn) do
          {:reply, response} -> reply(response, state)
          {:stream, spec} -> reply(StreamSpec.run(spec), state)
          :noreply -> state
        end
    end
  end

  defp reply(response, state) do
    case state.mode do
      {:slow, ms} -> Process.sleep(ms)
      {:garbage_stdout, n} -> for i <- 1..n, do: IO.binwrite(:stdio, "garbage line #{i}\n")
      _other -> :ok
    end

    IO.binwrite(:stdio, [JSON.encode!(response), ?\n])
    state = %{state | answered: state.answered + 1}

    case state.mode do
      {:exit_after, n} when state.answered >= n ->
        # Graceful, so the reply above is flushed before the exit.
        System.stop(3)
        Process.sleep(:infinity)

      _other ->
        state
    end
  end
end

ConduitMcp.Test.StdioServerScript.main(System.argv())
