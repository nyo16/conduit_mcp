defmodule ConduitMcp.Client.Negotiation do
  @moduledoc """
  Pure protocol-negotiation decisions for the client: which era a server
  speaks, which version to use, and which capabilities to advertise.

  ## Versions

  The client supports `"2026-07-28"`, `"2025-11-25"` and `"2025-06-18"`,
  newest first (`client_versions/0`). `2026-07-28` is the **modern** era
  (stateless, `server/discover`, per-request `_meta`); the others are
  **legacy** (`initialize` handshake).

  ## Probing (`classify_probe/3`)

  With `protocol: :auto` the client probes `server/discover` and reads the
  outcome with `classify_probe/3`. Which outcomes count as evidence of a
  legacy server depends on the transport:

  | Transport | Outcome | Verdict |
  |---|---|---|
  | both | valid `DiscoverResult` with a mutual modern version | `{:modern, version, result}` |
  | both | `DiscoverResult`-shaped but invalid, or no mutual modern version | `{:error, %Error{kind: :protocol}}` |
  | both | a result that is not `DiscoverResult`-shaped (no `resultType`, no `supportedVersions`) | `:legacy` |
  | both | `-32022` with a mutual modern version in `data.supported` | `{:modern_retry, version}` |
  | both | `-32022` without one | `{:error, %Error{reason: :no_common_version}}` |
  | both | `-32021` / `-32020` | `{:error, %Error{kind: :protocol}}`; never a fallback |
  | stdio | any other JSON-RPC error | `:legacy` |
  | stdio | timeout | `:legacy` |
  | stdio | the server process exited during the probe | `{:reconnect, :legacy}` |
  | HTTP | 401 / 403 | `{:authorize, status}` |
  | HTTP | 408 / 429 / 5xx, network error, timeout | `{:retry, reason}`; never a downgrade |
  | HTTP | 400 / 404 / 405 with a non-modern body (empty, not JSON, not JSON-RPC, or a non-modern error) | `:legacy` |
  | HTTP | any status with JSON-RPC `-32601` | `:legacy` |
  | HTTP | any other status or error | `{:error, %Error{}}` |

  A recognized modern error is never treated as legacy evidence, and the
  fallback is never keyed to one error code. Once a connection has reached a
  modern verdict, the caller pins the era and does not downgrade silently.

  ## Capabilities (`client_capabilities/2`)

  Built only from the `ConduitMcp.Client.Handler` callbacks a module
  implements; with no handler the client advertises `%{}`.
  """

  alias ConduitMcp.Client.{DiscoverResult, Error, SSE}

  @modern_version "2026-07-28"
  @client_versions [@modern_version, "2025-11-25", "2025-06-18"]

  # Mirror the modern error codes `ConduitMcp.Errors` defines for the server
  # (header_mismatch/0, missing_required_client_capability/0,
  # unsupported_protocol_version/0).
  @header_mismatch -32_020
  @missing_client_capability -32_021
  @unsupported_protocol_version -32_022
  @modern_error_codes [
    @header_mismatch,
    @missing_client_capability,
    @unsupported_protocol_version
  ]
  @method_not_found -32_601

  @legacy_evidence_statuses [400, 404, 405]

  @type era :: :modern | :legacy

  @type stdio_outcome ::
          {:result, term()} | {:error, map()} | :timeout | {:closed, term()}

  @type http_outcome ::
          {:http, status :: 100..599, content_type :: String.t() | nil,
           body :: binary() | map() | nil}
          | {:transport_error, term()}
          | :timeout

  @type verdict ::
          {:modern, String.t(), DiscoverResult.t()}
          | {:modern_retry, String.t()}
          | :legacy
          | {:reconnect, :legacy}
          | {:authorize, 401 | 403}
          | {:retry, term()}
          | {:error, Error.t()}

  @doc "Every protocol version the client speaks, newest first."
  @spec client_versions() :: [String.t(), ...]
  def client_versions, do: @client_versions

  @doc """
  The era of a protocol version string: dates on or after `2026-07-28` are
  `:modern`, earlier dates `:legacy`, anything else `:unknown`.

      iex> ConduitMcp.Client.Negotiation.era("2025-11-25")
      :legacy
  """
  @spec era(String.t()) :: era() | :unknown
  def era(<<_::binary-size(4), ?-, _::binary-size(2), ?-, _::binary-size(2)>> = version) do
    if version >= @modern_version, do: :modern, else: :legacy
  end

  def era(_version), do: :unknown

  @doc """
  Picks the version to use: the first entry of `client_supported` (in the
  client's preference order) that the server also lists.

      iex> ConduitMcp.Client.Negotiation.pick_version(["2025-06-18", "2025-11-25"])
      {:ok, "2025-11-25"}
      iex> ConduitMcp.Client.Negotiation.pick_version(["2024-11-05"])
      {:error, :no_common_version}
  """
  @spec pick_version([String.t()], [String.t()]) ::
          {:ok, String.t()} | {:error, :no_common_version}
  def pick_version(server_supported, client_supported \\ @client_versions)
      when is_list(server_supported) and is_list(client_supported) do
    case Enum.find(client_supported, &(&1 in server_supported)) do
      nil -> {:error, :no_common_version}
      version -> {:ok, version}
    end
  end

  @doc """
  Whether `code` is one of the modern-era JSON-RPC errors (`-32020`,
  `-32021`, `-32022`) that prove the server speaks `2026-07-28`.
  """
  @spec modern_error?(term()) :: boolean()
  def modern_error?(code), do: code in @modern_error_codes

  @doc """
  Classifies the outcome of a `server/discover` probe; see the moduledoc
  table.

  `outcome` is a `t:stdio_outcome/0` for `:stdio` and a `t:http_outcome/0`
  for `:http`. An HTTP body may be the raw bytes (decoded here as JSON for
  `application/json`, or as an event stream for `text/event-stream`) or an
  already decoded JSON-RPC message map.

  ## Options

    * `:versions` - the client's versions in preference order (default
      `client_versions/0`); only its modern entries are considered.
  """
  @spec classify_probe(:stdio | :http, stdio_outcome() | http_outcome(), keyword()) :: verdict()
  def classify_probe(transport, outcome, opts \\ [])

  def classify_probe(:stdio, :timeout, _opts), do: :legacy
  def classify_probe(:stdio, {:closed, _reason}, _opts), do: {:reconnect, :legacy}
  def classify_probe(:stdio, {:result, result}, opts), do: classify_result(result, opts)

  def classify_probe(:stdio, {:error, error}, opts) do
    case classify_modern_error(error, opts) do
      :not_modern -> :legacy
      verdict -> verdict
    end
  end

  def classify_probe(:http, :timeout, _opts), do: {:retry, :timeout}
  def classify_probe(:http, {:transport_error, reason}, _opts), do: {:retry, reason}

  def classify_probe(:http, {:http, status, _type, _body}, _opts) when status in [401, 403],
    do: {:authorize, status}

  def classify_probe(:http, {:http, status, _type, _body}, _opts)
      when status in [408, 429] or status >= 500,
      do: {:retry, {:http_status, status}}

  def classify_probe(:http, {:http, status, content_type, body}, opts) do
    classify_http_message(status, decode_body(content_type, body), opts)
  end

  @doc """
  The `ClientCapabilities` map to advertise for `handler` (a module
  implementing `ConduitMcp.Client.Handler`, or `nil`).

  Only implemented callbacks contribute, so `nil` or a module without
  sampling, elicitation or roots callbacks gives `%{}`.

  ## Options

    * `:era` - `:modern` (default) or `:legacy`; legacy roots may carry
      `listChanged`.
    * `:sampling_tools` - also declare `sampling.tools` (default `false`).
    * `:sampling_context` - also declare `sampling.context`, allowing
      `includeContext` other than `"none"` (default `false`).
    * `:roots_list_changed` - declare `roots.listChanged` in the legacy era,
      promising `notifications/roots/list_changed` (default `false`).

  ## Example

      iex> ConduitMcp.Client.Negotiation.client_capabilities(nil)
      %{}
  """
  @spec client_capabilities(module() | nil, keyword()) :: map()
  def client_capabilities(handler, opts \\ [])

  def client_capabilities(nil, _opts), do: %{}

  def client_capabilities(handler, opts) when is_atom(handler) do
    unless Code.ensure_loaded?(handler) do
      raise ArgumentError, "client handler #{inspect(handler)} is not an available module"
    end

    %{}
    |> put_if(exported?(handler, :handle_sampling, 2), "sampling", sampling_capability(opts))
    |> put_if(
      exported?(handler, :handle_elicitation, 2),
      "elicitation",
      elicitation_capability(handler)
    )
    |> put_if(exported?(handler, :list_roots, 1), "roots", roots_capability(opts))
  end

  defp exported?(module, function, arity), do: function_exported?(module, function, arity)

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp sampling_capability(opts) do
    %{}
    |> put_if(Keyword.get(opts, :sampling_tools, false) == true, "tools", %{})
    |> put_if(Keyword.get(opts, :sampling_context, false) == true, "context", %{})
  end

  defp elicitation_capability(handler) do
    modes =
      if exported?(handler, :elicitation_modes, 0),
        do: handler.elicitation_modes(),
        else: [:form]

    if modes == [] or not is_list(modes) or Enum.any?(modes, &(&1 not in [:form, :url])) do
      raise ArgumentError,
            "#{inspect(handler)}.elicitation_modes/0 must return a non-empty list of " <>
              ":form and :url, got: #{inspect(modes)}"
    end

    Map.new(modes, &{Atom.to_string(&1), %{}})
  end

  defp roots_capability(opts) do
    if Keyword.get(opts, :era, :modern) == :legacy and
         Keyword.get(opts, :roots_list_changed, false) == true,
       do: %{"listChanged" => true},
       else: %{}
  end

  defp modern_versions(opts) do
    opts |> Keyword.get(:versions, @client_versions) |> Enum.filter(&(era(&1) == :modern))
  end

  defp classify_result(result, opts) do
    case result do
      %{"supportedVersions" => _} -> discover_verdict(result, opts)
      %{"resultType" => _} -> discover_verdict(result, opts)
      _other -> :legacy
    end
  end

  defp discover_verdict(result, opts) do
    with {:ok, discover} <- DiscoverResult.from_wire(result),
         {:ok, version} <- pick_version(discover.supported_versions, modern_versions(opts)) do
      {:modern, version, discover}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :no_common_version} ->
        {:error,
         Error.new(:protocol, :no_common_version, %{"supported" => result["supportedVersions"]})}
    end
  end

  defp classify_modern_error(%{"code" => @unsupported_protocol_version} = error, opts) do
    supported =
      case error do
        %{"data" => %{"supported" => list}} when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    case pick_version(supported, modern_versions(opts)) do
      {:ok, version} ->
        {:modern_retry, version}

      {:error, :no_common_version} ->
        {:error, %{Error.from_rpc_error(error) | reason: :no_common_version}}
    end
  end

  defp classify_modern_error(%{"code" => @missing_client_capability} = error, _opts),
    do: {:error, %{Error.from_rpc_error(error) | reason: :missing_client_capability}}

  defp classify_modern_error(%{"code" => @header_mismatch} = error, _opts),
    do: {:error, %{Error.from_rpc_error(error) | reason: :header_mismatch}}

  defp classify_modern_error(_error, _opts), do: :not_modern

  defp classify_http_message(status, %{"error" => error}, opts) do
    case classify_modern_error(error, opts) do
      :not_modern -> classify_http_legacy_error(status, error)
      verdict -> verdict
    end
  end

  defp classify_http_message(status, %{"result" => result}, opts) when status in 200..299,
    do: classify_result(result, opts)

  defp classify_http_message(status, _not_rpc, _opts) when status in @legacy_evidence_statuses,
    do: :legacy

  defp classify_http_message(status, _not_rpc, _opts),
    do: {:error, Error.new(:transport, {:http_status, status})}

  defp classify_http_legacy_error(_status, %{"code" => @method_not_found}), do: :legacy

  defp classify_http_legacy_error(status, _error) when status in @legacy_evidence_statuses,
    do: :legacy

  defp classify_http_legacy_error(_status, error), do: {:error, Error.from_rpc_error(error)}

  defp decode_body(_type, %{} = message), do: message

  defp decode_body(type, body) when is_binary(body) do
    case media_type(type) do
      "application/json" -> decode_json(body)
      "text/event-stream" -> first_sse_response(body)
      _other -> nil
    end
  end

  defp decode_body(_type, _body), do: nil

  defp media_type(nil), do: nil

  defp media_type(type) do
    type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, %{} = message} -> message
      _ -> nil
    end
  end

  defp first_sse_response(body) do
    case SSE.feed(SSE.new(), body) do
      {:ok, events, _state} ->
        Enum.find_value(events, fn event ->
          case decode_json(event.data) do
            %{"result" => _} = message -> message
            %{"error" => _} = message -> message
            _ -> nil
          end
        end)

      {:error, _reason, _state} ->
        nil
    end
  end
end
