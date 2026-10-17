defmodule ConduitMcp.Progress do
  @moduledoc """
  Progress notifications from inside a running tool.

  A client asks for progress by sending a `progressToken` in the request's
  `_meta`. On the modern (`2026-07-28`) era over Streamable HTTP, such a
  `tools/call` is answered as a Server-Sent Events stream, and `report/3`
  sends a `notifications/progress` carrying that token ahead of the
  response:

      tool "import" do
        handle fn conn, %{"rows" => rows} ->
          total = length(rows)

          rows
          |> Enum.with_index(1)
          |> Enum.each(fn {row, done} ->
            import_row(row)
            ConduitMcp.Progress.report(conn, done, total: total, message: "row \#{done}")
          end)

          text("imported \#{total} rows")
        end
      end

  `report/3` is a no-op — it returns `:ok` and sends nothing — whenever there
  is no stream to send on: the request carried no `progressToken`, it is a
  legacy-era request (answered with a single JSON body), the client did not
  accept `text/event-stream`, or the call is running through
  `ConduitMcp.Handler.handle_request/3`. Tools can therefore call it
  unconditionally.

  Pass the `conn` the tool received. Notifications are sent asynchronously
  and arrive before the tool's response.
  """

  alias ConduitMcp.Notifications
  alias ConduitMcp.StreamSpec

  @doc """
  Reports `progress` (a number that should increase with every call) on the
  request `conn` belongs to.

  ## Options

    * `:total` — the total amount of work, when known
    * `:message` — a human-readable progress message

  Raises `ArgumentError` when `progress` or `:total` is not a number, or
  `:message` is not a string.
  """
  @spec report(Plug.Conn.t(), number(), keyword()) :: :ok
  def report(conn, progress, opts \\ []) do
    validate!(progress, Keyword.get(opts, :total), Keyword.get(opts, :message))

    StreamSpec.notify(conn, fn
      nil -> nil
      token -> Notifications.progress_notification(token, progress, opts)
    end)
  end

  defp validate!(progress, total, message) do
    cond do
      not is_number(progress) ->
        raise ArgumentError, "progress must be a number, got: #{inspect(progress)}"

      not (is_nil(total) or is_number(total)) ->
        raise ArgumentError, ":total must be a number, got: #{inspect(total)}"

      not (is_nil(message) or is_binary(message)) ->
        raise ArgumentError, ":message must be a string, got: #{inspect(message)}"

      true ->
        :ok
    end
  end
end
