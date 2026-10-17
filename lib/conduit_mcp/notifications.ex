defmodule ConduitMcp.Notifications do
  @moduledoc """
  Builders for server-to-client JSON-RPC notifications.

  Each function returns a complete notification message (`"jsonrpc"`,
  `"method"`, optional `"params"`, no `"id"`) ready to hand to a transport.
  The shapes are identical in the `2025-11-25` and `2026-07-28` schemas; what
  differs is delivery. On the legacy era they travel over a session stream;
  on `2026-07-28` list-changed and resource-updated notifications are only
  delivered on a `subscriptions/listen` stream the client opened, and log
  messages only when the request's `_meta` opted in.
  """

  alias ConduitMcp.Protocol

  @doc """
  Builds a `notifications/progress` notification.

  ## Options

    * `:total` - the total amount of work, when known
    * `:message` - a human-readable progress message

  ## Example

      ConduitMcp.Notifications.progress_notification("token-1", 50, total: 100)
  """
  @spec progress_notification(String.t() | integer(), number(), keyword()) :: map()
  def progress_notification(progress_token, progress, opts \\ []) do
    params =
      %{"progressToken" => progress_token, "progress" => progress}
      |> maybe_put("total", Keyword.get(opts, :total))
      |> maybe_put("message", Keyword.get(opts, :message))

    Protocol.notification("notifications/progress", params)
  end

  @doc """
  Builds a `notifications/message` log notification.

  `level` is an RFC 5424 level string (`"debug"` … `"emergency"`); `data` is
  any JSON-serializable value.

  ## Options

    * `:logger` - the name of the logger issuing the message
  """
  @spec log_notification(String.t(), term(), keyword()) :: map()
  def log_notification(level, data, opts \\ []) do
    params =
      %{"level" => level, "data" => data}
      |> maybe_put("logger", Keyword.get(opts, :logger))

    Protocol.notification("notifications/message", params)
  end

  @doc "Builds a `notifications/resources/updated` notification for `uri`."
  @spec resource_updated_notification(String.t()) :: map()
  def resource_updated_notification(uri) do
    Protocol.notification("notifications/resources/updated", %{"uri" => uri})
  end

  @doc "Builds a `notifications/resources/list_changed` notification."
  @spec resource_list_changed_notification() :: map()
  def resource_list_changed_notification do
    Protocol.notification("notifications/resources/list_changed")
  end

  @doc "Builds a `notifications/tools/list_changed` notification."
  @spec tool_list_changed_notification() :: map()
  def tool_list_changed_notification do
    Protocol.notification("notifications/tools/list_changed")
  end

  @doc "Builds a `notifications/prompts/list_changed` notification."
  @spec prompt_list_changed_notification() :: map()
  def prompt_list_changed_notification do
    Protocol.notification("notifications/prompts/list_changed")
  end

  @doc """
  Builds a `notifications/subscriptions/acknowledged` notification: the first
  message on a `subscriptions/listen` stream, carrying the filter subset the
  server honours (`ConduitMcp.Subscriptions.Filter`). `2026-07-28` only.
  """
  @spec subscriptions_acknowledged_notification(map()) :: map()
  def subscriptions_acknowledged_notification(notifications) when is_map(notifications) do
    Protocol.notification("notifications/subscriptions/acknowledged", %{
      "notifications" => notifications
    })
  end

  @doc """
  Builds a `notifications/cancelled` notification for `request_id`.

  A `2026-07-28` server sends it for one purpose only: to end the
  `subscriptions/listen` stream that `request_id` opened.
  """
  @spec cancelled_notification(String.t() | integer(), String.t() | nil) :: map()
  def cancelled_notification(request_id, reason \\ nil) do
    params = maybe_put(%{"requestId" => request_id}, "reason", reason)
    Protocol.notification("notifications/cancelled", params)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
