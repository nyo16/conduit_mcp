defmodule ConduitMcp.Log do
  @moduledoc """
  Log notifications (`notifications/message`) from inside a running tool.

  On the modern (`2026-07-28`) era a client opts into log messages per
  request, with `_meta["io.modelcontextprotocol/logLevel"]`. Such a
  `tools/call` is answered over Streamable HTTP as a Server-Sent Events
  stream, and `log/4` sends a `notifications/message` ahead of the response
  when `level` is at least as severe as the requested level:

      handle fn conn, %{"query" => query} ->
        ConduitMcp.Log.log(conn, :info, %{"query" => "planning"}, logger: "sql")
        text(run(query))
      end

  The specification forbids log notifications for a request that did not
  ask for them, so `log/4` sends nothing — and returns `:ok` — when the
  request carried no `logLevel`, when `level` is below it
  (`ConduitMcp.Ctx.log?/2`), and whenever there is no stream to send on: a
  legacy-era request (answered with a single JSON body), a client that did
  not accept `text/event-stream`, or a call running through
  `ConduitMcp.Handler.handle_request/3`. Tools can therefore call it
  unconditionally.

  Never log credentials or other secrets: the client receives `data` as is.
  """

  alias ConduitMcp.Ctx
  alias ConduitMcp.Notifications
  alias ConduitMcp.StreamSpec

  @typedoc "An MCP logging level, as an atom or a string (`:info` or `\"info\"`)."
  @type level ::
          :debug
          | :info
          | :notice
          | :warning
          | :error
          | :critical
          | :alert
          | :emergency
          | String.t()

  @doc """
  Sends a `notifications/message` at `level` with JSON-serializable `data`
  on the request `conn` belongs to, when that request asked for it.

  ## Options

    * `:logger` — the name of the logger issuing the message

  Raises `ArgumentError` for a level that is not an MCP logging level.
  """
  @spec log(Plug.Conn.t(), level(), term(), keyword()) :: :ok
  def log(conn, level, data, opts \\ []) do
    level = normalize!(level)

    case Ctx.from_conn(conn) do
      %Ctx{} = ctx ->
        if Ctx.log?(ctx, level),
          do: StreamSpec.notify(conn, fn _token -> message(level, data, opts) end),
          else: :ok

      nil ->
        :ok
    end
  end

  defp message(level, data, opts),
    do: Notifications.log_notification(level, data, Keyword.take(opts, [:logger]))

  defp normalize!(level) when is_atom(level), do: normalize!(Atom.to_string(level))

  defp normalize!(level) when is_binary(level) do
    if level in Ctx.log_levels(),
      do: level,
      else: raise(ArgumentError, "not an MCP logging level: #{inspect(level)}")
  end

  defp normalize!(level),
    do: raise(ArgumentError, "not an MCP logging level: #{inspect(level)}")
end
