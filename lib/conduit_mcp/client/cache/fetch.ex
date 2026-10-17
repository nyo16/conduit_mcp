defmodule ConduitMcp.Client.Cache.Fetch do
  @moduledoc false

  # Fetching lists from the server, in the calling process: one page for
  # `ConduitMcp.Client.list_tools/2` and friends, every page for a cache
  # refresh (run by the connection in a task under the client's
  # `Task.Supervisor`, never in the connection itself).
  #
  # Pagination caps (HT-10), each a `:pagination_cycle` error:
  #
  #   * `:max_pages` - more than 100 pages;
  #   * `:max_items` - more than 10_000 items in total;
  #   * `:repeated_cursor` - a `nextCursor` the listing already used;
  #   * `:cursor_too_large` - a `nextCursor` over 1 KiB.
  #
  # Cursors are opaque: never parsed, never kept beyond the listing.

  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Intake
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Telemetry

  @max_pages 100
  @max_items 10_000
  @max_cursor_bytes 1024

  @methods %{
    tools: {"tools/list", "tools"},
    prompts: {"prompts/list", "prompts"},
    resources: {"resources/list", "resources"},
    resource_templates: {"resources/templates/list", "resourceTemplates"}
  }

  @type page :: %{
          items: [term()],
          rejected: non_neg_integer(),
          next_cursor: String.t() | nil,
          ttl_ms: non_neg_integer(),
          seen: MapSet.t()
        }

  @type listing :: %{
          items: [term()],
          pages: pos_integer(),
          rejected: non_neg_integer(),
          ttl_ms: non_neg_integer()
        }

  @doc "The pagination caps."
  @spec caps() :: %{
          max_pages: pos_integer(),
          max_items: pos_integer(),
          max_cursor_bytes: pos_integer()
        }
  def caps,
    do: %{max_pages: @max_pages, max_items: @max_items, max_cursor_bytes: @max_cursor_bytes}

  @doc "The intake context for `client` (`ConduitMcp.Client.Intake`)."
  @spec context(term(), map()) :: Intake.ctx()
  def context(client, view) do
    %{
      server_id: view.server_id,
      http?: view.transport == :http,
      telemetry: Telemetry.base(client, view.server_id, view.transport, view.era)
    }
  end

  @doc """
  Fetches one page of `kind` starting at `cursor`. `opts` are
  `ConduitMcp.Client.Request.run/4` options plus `:meta` (the request's
  user `_meta`).
  """
  @spec page(term(), Intake.kind(), String.t() | nil, keyword(), Intake.ctx(), MapSet.t()) ::
          {:ok, page()} | {:error, Error.t()}
  def page(client, kind, cursor, opts, ctx, seen \\ MapSet.new()) do
    {method, key} = Map.fetch!(@methods, kind)
    {meta, opts} = Keyword.pop(opts, :meta)

    params =
      %{}
      |> put_present("cursor", cursor)
      |> put_present("_meta", meta)

    with {:ok, result} <- Request.run(client, method, params, opts),
         {:ok, items, rejected, seen} <- Intake.decode(kind, Map.get(result, key, []), ctx, seen) do
      {:ok,
       %{
         items: items,
         rejected: rejected,
         next_cursor: next_cursor(result),
         ttl_ms: ttl_hint(result),
         seen: seen
       }}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Fetches every page of `kind`. `ttl_ms` is the smallest `ttlMs` hint over
  the pages (0 when any page has none); the caller clamps it.
  """
  @spec all(term(), Intake.kind(), keyword()) :: {:ok, listing()} | {:error, Error.t()}
  def all(client, kind, opts) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      ctx = context(client, view)
      acc = %{items: [], count: 0, pages: 0, rejected: 0, ttl_ms: nil, seen: MapSet.new()}
      loop(client, kind, nil, %{}, opts, ctx, acc)
    end
  end

  # `cursors` (a plain map, cursor => true) holds every cursor sent so far.
  defp loop(client, kind, cursor, cursors, opts, ctx, acc) do
    with {:ok, page} <- page(client, kind, cursor, opts, ctx, acc.seen) do
      acc = %{
        acc
        | items: [page.items | acc.items],
          count: acc.count + length(page.items),
          pages: acc.pages + 1,
          rejected: acc.rejected + page.rejected,
          ttl_ms: min_ttl(acc.ttl_ms, page.ttl_ms),
          seen: page.seen
      }

      case next(page.next_cursor, cursors, acc) do
        :done ->
          {:ok,
           %{
             items: acc.items |> Enum.reverse() |> Enum.concat(),
             pages: acc.pages,
             rejected: acc.rejected,
             ttl_ms: acc.ttl_ms
           }}

        {:next, cursor} ->
          loop(client, kind, cursor, Map.put(cursors, cursor, true), opts, ctx, acc)

        {:error, _} = error ->
          error
      end
    end
  end

  defp next(cursor, cursors, acc) do
    cond do
      acc.count > @max_items -> cap(:max_items, @max_items)
      cursor == nil -> :done
      byte_size(cursor) > @max_cursor_bytes -> cap(:cursor_too_large, @max_cursor_bytes)
      Map.has_key?(cursors, cursor) -> cap(:repeated_cursor, nil)
      acc.pages >= @max_pages -> cap(:max_pages, @max_pages)
      true -> {:next, cursor}
    end
  end

  defp cap(reason, limit), do: {:error, Error.new(:pagination_cycle, reason, %{limit: limit})}

  defp min_ttl(nil, ttl), do: ttl
  defp min_ttl(acc, ttl), do: min(acc, ttl)

  defp ttl_hint(%{"ttlMs" => ttl}) when is_integer(ttl) and ttl >= 0, do: ttl
  defp ttl_hint(_result), do: 0

  defp next_cursor(%{"nextCursor" => cursor}) when is_binary(cursor), do: cursor
  defp next_cursor(_result), do: nil
end
