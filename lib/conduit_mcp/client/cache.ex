defmodule ConduitMcp.Client.Cache do
  @moduledoc """
  The per-connection cache of a `ConduitMcp.Client`: an ETS table
  (`:set`, `:protected`, `read_concurrency: true`) that only the client's
  `ConduitMcp.Client.Connection` writes, and that any process reads
  directly. Its id is published in the client's `ConduitMcp.Client.Registry`
  value, so readers never message the connection.

  ## Rows

    * `{:status, %{state:, era:, version:, reason:, origin:}}` - the
      connection state (`ConduitMcp.Client.status/1`).
    * `{:server, server | nil}` - what the server reported in the handshake
      (`ConduitMcp.Client.server_info/1`).
    * `{kind, version, items, fetched_at, expires_at, stale?}` - one list,
      for `kind` in `:tools`, `:prompts`, `:resources` and
      `:resource_templates`.
    * `{{:tool, name}, version, %ConduitMcp.Client.Tool{}}` - a point row
      per item, so a lookup copies one item instead of the list. Prompts are
      keyed `{:prompt, name}`, resources `{:resource, uri}`, templates
      `{:resource_template, uri_template}`.
    * `{:version, n}` - the counter list writes take their version from.

  A list is written with one `:ets.insert/2` of the list row and its point
  rows, then the point rows of earlier versions are deleted, so a reader
  never sees a half-written list.

  ## Freshness

  `fetched_at` and `expires_at` are `System.monotonic_time(:millisecond)`
  values. `expires_at` is `fetched_at` plus the server's `ttlMs` hint
  (the minimum over the pages), clamped to the client's `:max_cache_ttl`;
  a missing, negative or non-integer `ttlMs` means 0, so by default a list
  is never fresh and `ConduitMcp.Client.list_all_tools/2` fetches again.
  Nothing polls on TTL: a list is refreshed when a caller asks for it after
  it expired, when the server sends `notifications/*/list_changed` (which
  also marks it stale at once), and it is marked stale when the connection
  is lost. Multi-round-trip interim results and retries are never cached.

  A server's `cacheScope: "private"` means the answer may differ per
  credential. A client holds one credential, so the cache is per
  credential; run one client per credential (per user) when they differ.

  ## Dead tables

  The table dies with its connection. A read that races that gets
  `{:error, %ConduitMcp.Client.Error{kind: :unavailable, reason: :cache_gone}}`
  instead of an `ArgumentError`.
  """

  alias ConduitMcp.Client.Error

  @kinds [:tools, :prompts, :resources, :resource_templates]
  @point_tags %{
    tools: :tool,
    prompts: :prompt,
    resources: :resource,
    resource_templates: :resource_template
  }

  @typedoc "A cached list kind."
  @type kind :: :tools | :prompts | :resources | :resource_templates

  @typedoc "A cached list."
  @type entry :: %{
          items: [term()],
          version: pos_integer(),
          fetched_at: integer(),
          expires_at: integer(),
          stale?: boolean()
        }

  @doc "Every cached list kind."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  # --- writes (the connection only) ---------------------------------------------

  @doc false
  @spec new() :: :ets.tid()
  def new, do: :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

  @doc false
  @spec put_status(:ets.tid(), map()) :: true
  def put_status(tid, status), do: :ets.insert(tid, {:status, status})

  @doc false
  @spec put_server(:ets.tid(), map() | nil) :: true
  def put_server(tid, server), do: :ets.insert(tid, {:server, server})

  @doc false
  # Writes `items` as the `kind` list, fetched at `now`, fresh for `ttl_ms`.
  @spec put_list(:ets.tid(), kind(), [term()], non_neg_integer(), integer()) :: pos_integer()
  def put_list(tid, kind, items, ttl_ms, now) when kind in @kinds do
    version = :ets.update_counter(tid, :version, 1, {:version, 0})
    tag = Map.fetch!(@point_tags, kind)

    points =
      Enum.flat_map(items, fn item ->
        case point_key(kind, item) do
          nil -> []
          key -> [{{tag, key}, version, item}]
        end
      end)

    true = :ets.insert(tid, [{kind, version, items, now, now + ttl_ms, false} | points])
    _deleted = :ets.select_delete(tid, [{{{tag, :_}, :"$1", :_}, [{:<, :"$1", version}], [true]}])
    version
  end

  @doc false
  # Marks the `kind` list stale (no-op when it was never fetched).
  @spec mark_stale(:ets.tid(), kind()) :: boolean()
  def mark_stale(tid, kind) when kind in @kinds, do: :ets.update_element(tid, kind, {6, true})

  @doc false
  @spec mark_all_stale(:ets.tid()) :: :ok
  def mark_all_stale(tid), do: Enum.each(@kinds, &mark_stale(tid, &1))

  @doc false
  # Whether the `kind` list was ever fetched (the owner decides on
  # `list_changed` whether to refresh it).
  @spec cached?(:ets.tid(), kind()) :: boolean()
  def cached?(tid, kind), do: :ets.member(tid, kind)

  @doc """
  The TTL in milliseconds for a server `ttlMs` hint: a non-negative
  integer clamped to `max`; anything else is 0.

      iex> ConduitMcp.Client.Cache.ttl(90_000, 3_600_000)
      90000
      iex> ConduitMcp.Client.Cache.ttl(nil, 3_600_000)
      0
      iex> ConduitMcp.Client.Cache.ttl(10_000_000, 3_600_000)
      3600000
  """
  @spec ttl(term(), non_neg_integer()) :: non_neg_integer()
  def ttl(ttl_ms, max) when is_integer(ttl_ms) and ttl_ms >= 0, do: min(ttl_ms, max)
  def ttl(_ttl_ms, _max), do: 0

  # --- reads (any process) ---------------------------------------------------------

  @doc "The `:status` row merged with the `:server` row (`server: nil` before a handshake)."
  @spec status(:ets.tid()) :: {:ok, map()} | {:error, Error.t()}
  def status(tid) do
    with {:ok, [{:status, status}]} <- lookup_rows(tid, :status),
         {:ok, server_rows} <- lookup_rows(tid, :server) do
      server =
        case server_rows do
          [{:server, server}] -> server
          [] -> nil
        end

      {:ok, Map.put(status, :server, server)}
    else
      {:ok, []} -> {:error, Error.new(:unavailable, :starting)}
      {:error, _} = error -> error
    end
  end

  @doc "The cached `kind` list, `:miss` when it was never fetched."
  @spec list(:ets.tid(), kind()) :: {:ok, entry()} | :miss | {:error, Error.t()}
  def list(tid, kind) when kind in @kinds do
    case lookup_rows(tid, kind) do
      {:ok, [{^kind, version, items, fetched_at, expires_at, stale?}]} ->
        {:ok,
         %{
           items: items,
           version: version,
           fetched_at: fetched_at,
           expires_at: expires_at,
           stale?: stale?
         }}

      {:ok, []} ->
        :miss

      {:error, _} = error ->
        error
    end
  end

  @doc "Whether `entry` may be served without asking the server again."
  @spec fresh?(entry(), integer()) :: boolean()
  def fresh?(%{stale?: stale?, expires_at: expires_at}, now),
    do: not stale? and now < expires_at

  @doc """
  The cached item of `kind` keyed `key` (a tool or prompt name, a resource
  URI, a template's `uriTemplate`), `:miss` when it is not in the last
  fetched list.
  """
  @spec lookup(:ets.tid(), kind(), String.t()) :: {:ok, term()} | :miss | {:error, Error.t()}
  def lookup(tid, kind, key) when kind in @kinds do
    point = {Map.fetch!(@point_tags, kind), key}

    case lookup_rows(tid, point) do
      {:ok, [{^point, _version, item}]} -> {:ok, item}
      {:ok, []} -> :miss
      {:error, _} = error -> error
    end
  end

  # The one place a dead table surfaces: `:ets.lookup/2` on a deleted table
  # raises `ArgumentError`, and nothing else in here can.
  defp lookup_rows(tid, key) do
    {:ok, :ets.lookup(tid, key)}
  rescue
    ArgumentError -> {:error, Error.new(:unavailable, :cache_gone)}
  end

  defp point_key(:tools, %{name: name}), do: name
  defp point_key(:prompts, %{name: name}), do: name
  defp point_key(:resources, %{uri: uri}), do: uri

  defp point_key(:resource_templates, %{"uriTemplate" => template}) when is_binary(template),
    do: template

  defp point_key(_kind, _item), do: nil
end
