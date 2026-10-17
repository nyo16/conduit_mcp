defmodule ConduitMcp.Client.Connection.Refresh do
  @moduledoc false

  # Cache refreshes. The connection is the only writer of the cache table
  # but never fetches: a refresh runs `ConduitMcp.Client.Cache.Fetch.all/3`
  # in a task under the client's `Task.Supervisor` (an ordinary caller of
  # this connection), and its result comes back here to be written.
  #
  #   * On demand (`ConduitMcp.Client.list_all_tools/2` and friends, when
  #     the cached list is not fresh): callers asking while a refresh runs
  #     wait for that one (single flight).
  #   * On `notifications/*/list_changed` (already coalesced by
  #     `ConduitMcp.Client.Connection.Inbound`): the list is marked stale
  #     and, if it was ever fetched, refreshed. One arriving while a refresh
  #     runs only schedules one more after it, so a burst costs at most two.
  #     `list_changed` refreshes of one kind start at most once a second
  #     (HB-4): one due sooner waits for the second to pass, so a sustained
  #     storm costs one fetch per second per kind.
  #
  # Writing a tools list emits `[:conduit_mcp, :client, :tool,
  # :definition_changed]` for every known tool whose fingerprint changed.

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Cache.Fetch
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Telemetry

  @refetch_interval_ms 1_000

  @kinds_by_method %{
    "notifications/tools/list_changed" => [:tools],
    "notifications/prompts/list_changed" => [:prompts],
    "notifications/resources/list_changed" => [:resources, :resource_templates]
  }

  @doc "A caller (`mref`) wants the `kind` list refreshed."
  @spec demand(Cache.kind(), reference(), keyword(), Data.t()) :: Data.t()
  def demand(kind, mref, opts, data) do
    case Map.fetch(data.refreshes, kind) do
      {:ok, refresh} -> put_refresh(data, kind, %{refresh | waiters: [mref | refresh.waiters]})
      :error -> start(kind, [mref], opts, :demand, data)
    end
  end

  @doc "A delivered `list_changed` notification `method`."
  @spec list_changed(String.t(), Data.t()) :: Data.t()
  def list_changed(method, data) do
    @kinds_by_method
    |> Map.get(method, [])
    |> Enum.reduce(data, fn kind, data ->
      Cache.mark_stale(data.cache, kind)

      cond do
        Map.has_key?(data.refreshes, kind) ->
          put_refresh(data, kind, %{Map.fetch!(data.refreshes, kind) | again?: true})

        Cache.cached?(data.cache, kind) ->
          refetch(kind, [], data)

        true ->
          data
      end
    end)
  end

  @doc """
  The once-a-second cap released `kind` (the connection is ready): refresh
  it now, or after the refresh already running.
  """
  @spec deferred(Cache.kind(), Data.t()) :: Data.t()
  def deferred(kind, data) do
    data = drop_deferred(kind, data)

    cond do
      Map.has_key?(data.refreshes, kind) ->
        put_refresh(data, kind, %{Map.fetch!(data.refreshes, kind) | again?: true})

      Cache.cached?(data.cache, kind) ->
        refetch(kind, [], data)

      true ->
        data
    end
  end

  @doc "Forgets a held-back refresh (the connection is not ready; lists are stale)."
  @spec drop_deferred(Cache.kind(), Data.t()) :: Data.t()
  def drop_deferred(kind, data) do
    case Map.fetch(data.coalesce, {:refetch, kind}) do
      {:ok, entry} -> put_refetch(data, kind, %{entry | deferred?: false})
      :error -> data
    end
  end

  # A `list_changed` refresh, unless one started less than a second ago:
  # then it is held back until the second has passed (once per kind). The
  # last start lives in `data.coalesce` under `{:refetch, kind}`.
  defp refetch(kind, opts, data) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(data.coalesce, {:refetch, kind}) do
      {:ok, %{at: last, deferred?: true}} when now - last < @refetch_interval_ms ->
        data

      {:ok, %{at: last} = entry} when now - last < @refetch_interval_ms ->
        Process.send_after(self(), {:"$mcp_refetch", kind}, @refetch_interval_ms - (now - last))
        put_refetch(data, kind, %{entry | deferred?: true})

      _never_or_long_ago ->
        data = put_refetch(data, kind, %{at: now, deferred?: false})
        start(kind, [], opts, :list_changed, data)
    end
  end

  defp put_refetch(data, kind, entry),
    do: %{data | coalesce: Map.put(data.coalesce, {:refetch, kind}, entry)}

  defp start(kind, waiters, opts, trigger, data) do
    metadata = Telemetry.inherited_logger_metadata()
    name = data.name

    task =
      Task.Supervisor.async_nolink(data.task_sup, fn ->
        Logger.metadata(metadata)
        Fetch.all(name, kind, opts)
      end)

    Telemetry.cache_refresh_start(Data.telemetry(data), kind, trigger)

    refresh = %{
      ref: task.ref,
      waiters: waiters,
      again?: false,
      opts: opts,
      trigger: trigger,
      started: System.monotonic_time()
    }

    put_refresh(data, kind, refresh)
  end

  defp put_refresh(data, kind, refresh),
    do: %{data | refreshes: Map.put(data.refreshes, kind, refresh)}

  @doc "The refresh task of `kind` answered."
  @spec done(Cache.kind(), reference(), term(), Data.t()) :: Data.t()
  def done(kind, ref, result, data) do
    Process.demonitor(ref, [:flush])
    finish(kind, result, data)
  end

  @doc "The refresh task of `kind` exited without answering."
  @spec down(Cache.kind(), Data.t()) :: Data.t()
  def down(kind, data), do: finish(kind, {:error, Error.new(:unavailable, :refresh_failed)}, data)

  defp finish(kind, result, data) do
    {refresh, refreshes} = Map.pop(data.refreshes, kind)
    data = %{data | refreshes: refreshes}

    reply =
      case result do
        {:ok, listing} ->
          store(kind, listing, data)
          if refresh.again?, do: Cache.mark_stale(data.cache, kind)
          {:ok, listing.items}

        {:error, %Error{}} = error ->
          error
      end

    Telemetry.cache_refresh_stop(
      Data.telemetry(data),
      kind,
      refresh.trigger,
      refresh.started,
      result
    )

    Enum.each(refresh.waiters, &Requests.reply(&1, reply))

    if refresh.again?,
      do: refetch(kind, refresh.opts, data),
      else: data
  end

  defp store(kind, listing, data) do
    if kind == :tools, do: report_changes(listing.items, data)
    ttl = Cache.ttl(listing.ttl_ms, data.config.max_cache_ttl)
    Cache.put_list(data.cache, kind, listing.items, ttl, System.monotonic_time(:millisecond))
  end

  defp report_changes(tools, data) do
    with {:ok, %{items: old}} <- Cache.list(data.cache, :tools) do
      known = Map.new(old, &{&1.name, &1.fingerprint})

      for tool <- tools,
          Map.has_key?(known, tool.name),
          Map.fetch!(known, tool.name) != tool.fingerprint do
        Telemetry.definition_changed(Data.telemetry(data), tool.name)
      end
    end

    :ok
  end
end
