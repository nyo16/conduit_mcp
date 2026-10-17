defmodule ConduitMcp.Client.Connection.Notifier do
  @moduledoc false

  # Runs the handler's `handle_notification/3` and `handle_log/3` outside the
  # connection, one notification at a time and in arrival order. Started by
  # the connection (linked, and monitoring it) only when the handler
  # implements one of them. A raising callback is logged and skipped. When
  # 1 000 notifications are already waiting, new ones are dropped so a slow
  # callback cannot grow memory without bound.

  require Logger

  @max_queue 1_000

  @doc "Starts the notifier for `handler`, or returns `nil` when it has no such callbacks."
  @spec start(module() | nil, map()) :: pid() | nil
  def start(nil, _ctx), do: nil

  def start(handler, ctx) do
    if function_exported?(handler, :handle_notification, 3) or
         function_exported?(handler, :handle_log, 3) do
      owner = self()

      spawn_link(fn ->
        ref = Process.monitor(owner)
        loop(handler, ctx, ref)
      end)
    end
  end

  @doc "Queues a server notification for the handler."
  @spec notify(pid() | nil, String.t(), map(), :modern | :legacy | nil) :: :ok
  def notify(nil, _method, _params, _era), do: :ok

  def notify(pid, method, params, era) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queued} when queued < @max_queue ->
        send(pid, {:notify, method, params, era})
        :ok

      _full_or_gone ->
        :ok
    end
  end

  defp loop(handler, ctx, ref) do
    receive do
      {:notify, method, params, era} ->
        dispatch(handler, method, params, Map.put(ctx, :era, era))
        loop(handler, ctx, ref)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  defp dispatch(handler, method, params, ctx) do
    case {method, params} do
      {"notifications/message", %{"level" => level}} when is_binary(level) ->
        if function_exported?(handler, :handle_log, 3),
          do: handler.handle_log(level, params, ctx),
          else: other(handler, method, params, ctx)

      _other ->
        other(handler, method, params, ctx)
    end
  catch
    kind, _reason ->
      Logger.warning(
        "MCP client handler #{inspect(handler)} failed on a notification (#{kind}); skipped"
      )
  end

  defp other(handler, method, params, ctx) do
    if function_exported?(handler, :handle_notification, 3),
      do: handler.handle_notification(method, params, ctx)
  end
end
