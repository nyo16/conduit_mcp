defmodule ConduitMcp.Client.DiscoverResult do
  @moduledoc """
  A modern (`2026-07-28`) server's answer to `server/discover`.

    * `supported_versions` - `supportedVersions`, in the server's order.
    * `capabilities` - the server's `ServerCapabilities`, string-keyed.
    * `instructions` - optional server instructions, or `nil`.
    * `ttl_ms` - how long the result may be cached. An absent, negative or
      non-integer `ttlMs` reads as `0`, as the caching page requires; any
      upper clamp is the cache's job.
    * `cache_scope` - `:public` or `:private`. Anything else (or absent)
      reads as `:private`, the scope that never shares across credentials.
    * `server_info` - `_meta["io.modelcontextprotocol/serverInfo"]` as a
      `ConduitMcp.Client.ServerInfo`, or `nil` when absent or malformed (it is
      a SHOULD, and display-only).
    * `meta` - the result's `_meta`, or `%{}`.
    * `raw` - the whole string-keyed wire map.
  """

  alias ConduitMcp.Client.{ServerInfo, Wire}

  @server_info_key "io.modelcontextprotocol/serverInfo"

  @enforce_keys [:supported_versions, :capabilities, :raw]
  defstruct [
    :supported_versions,
    :capabilities,
    :instructions,
    :server_info,
    :raw,
    ttl_ms: 0,
    cache_scope: :private,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          supported_versions: [String.t()],
          capabilities: map(),
          instructions: String.t() | nil,
          ttl_ms: non_neg_integer(),
          cache_scope: :public | :private,
          server_info: ServerInfo.t() | nil,
          meta: map(),
          raw: map()
        }

  @doc """
  Builds a `DiscoverResult` from a `server/discover` result map.

  `supportedVersions` must be a list of strings and `capabilities` an
  object, and `resultType` must be absent or `"complete"`; otherwise the
  result is a `:protocol` error with reason `:invalid_discover_result`.

      iex> {:ok, result} =
      ...>   ConduitMcp.Client.DiscoverResult.from_wire(%{
      ...>     "resultType" => "complete",
      ...>     "supportedVersions" => ["2026-07-28"],
      ...>     "capabilities" => %{"tools" => %{}},
      ...>     "ttlMs" => 60_000,
      ...>     "cacheScope" => "public"
      ...>   })
      iex> {result.supported_versions, result.ttl_ms, result.cache_scope}
      {["2026-07-28"], 60000, :public}
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(%{"supportedVersions" => versions, "capabilities" => caps} = raw)
      when is_list(versions) and is_map(caps) do
    if Enum.all?(versions, &is_binary/1) and Map.get(raw, "resultType", "complete") == "complete" do
      meta = Wire.meta(raw)

      {:ok,
       %__MODULE__{
         supported_versions: versions,
         capabilities: caps,
         instructions: Wire.string(raw, "instructions"),
         ttl_ms: ttl_ms(Map.get(raw, "ttlMs")),
         cache_scope: cache_scope(Map.get(raw, "cacheScope")),
         server_info: server_info(meta),
         meta: meta,
         raw: raw
       }}
    else
      Wire.invalid(:invalid_discover_result, raw)
    end
  end

  def from_wire(other), do: Wire.invalid(:invalid_discover_result, other)

  defp ttl_ms(ttl) when is_integer(ttl) and ttl > 0, do: ttl
  defp ttl_ms(_ttl), do: 0

  defp cache_scope("public"), do: :public
  defp cache_scope(_scope), do: :private

  defp server_info(%{@server_info_key => info}) do
    case ServerInfo.from_wire(info) do
      {:ok, server_info} -> server_info
      {:error, _} -> nil
    end
  end

  defp server_info(_meta), do: nil
end
