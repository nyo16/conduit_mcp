defmodule ConduitMcp.Client.OAuth.Discovery do
  @moduledoc """
  Pure parts of authorization-server discovery (MCP authorization spec,
  *Authorization Server Discovery*): the metadata URLs to try, in order, and
  validation of the decoded metadata documents. Nothing here does I/O; the
  HTTP layer fetches each candidate (without an `Authorization` header, with
  every URL passing `ConduitMcp.Client.URLPolicy` `:public_only`) and stops
  at the first usable document.

  ## Protected Resource Metadata (RFC 9728)

  `prm_candidates/3` for server `https://ex.com/public/mcp`:

    1. the `resource_metadata` URL from the `WWW-Authenticate` challenge, when given;
    2. `https://ex.com/.well-known/oauth-protected-resource/public/mcp`;
    3. `https://ex.com/.well-known/oauth-protected-resource`.

  `validate_prm/2` then requires `resource` to equal the canonical server URI
  **exactly** (RFC 9728 §3.3; no prefix or same-origin relaxation, OA-4) and
  a non-empty `authorization_servers`; `select_issuer/2` picks the first one.

  ## Authorization-server metadata (RFC 8414, OpenID Connect Discovery)

  `as_metadata_candidates/2` for issuer `https://auth.ex.com/tenant1`:

    1. `https://auth.ex.com/.well-known/oauth-authorization-server/tenant1`
    2. `https://auth.ex.com/.well-known/openid-configuration/tenant1`
    3. `https://auth.ex.com/tenant1/.well-known/openid-configuration`

  and for an issuer without a path, `/.well-known/oauth-authorization-server`
  then `/.well-known/openid-configuration`.

  `validate_as_metadata/3` then requires (OA-1, OA-4, OA-7):

    * `issuer` to equal the issuer the URLs were built from, by exact string
      comparison (RFC 8414 §3.3): `https://AS.example` is not
      `https://as.example`, and a trailing slash matters;
    * `"S256"` in `code_challenge_methods_supported`;
    * `authorization_endpoint` and `token_endpoint` to be present;
    * every endpoint - each top-level field ending in `_endpoint`, plus
      `jwks_uri` - to be an `https` URL with a host, no user info and no
      fragment. `https` is the whole scheme allowlist, so `javascript:`,
      `file:`, `data:` and custom schemes are refused as `:insecure_endpoint`.

  Every builder and validator accepts `allow_insecure: true`, which admits
  `http` on loopback hosts only, for local development and tests.
  """

  alias ConduitMcp.Client.OAuth.{Error, PKCE, URL}

  @prm_path "/.well-known/oauth-protected-resource"
  @oauth_path "/.well-known/oauth-authorization-server"
  @oidc_path "/.well-known/openid-configuration"

  @required_endpoints ["authorization_endpoint", "token_endpoint"]

  @doc """
  The Protected Resource Metadata URLs to try for `server_url`, in order.

  `resource_metadata` (from `ConduitMcp.Client.OAuth.Challenge.resource_metadata/1`)
  goes first, unchanged; it is server data and must pass the URL policy when
  fetched. The well-known URLs are built from the canonical server URI
  (`ConduitMcp.Client.OAuth.Resource.canonical/2`), keeping any query after
  the inserted path. Duplicates are removed.

      iex> ConduitMcp.Client.OAuth.Discovery.prm_candidates("https://ex.com/public/mcp")
      {:ok,
       [
         "https://ex.com/.well-known/oauth-protected-resource/public/mcp",
         "https://ex.com/.well-known/oauth-protected-resource"
       ]}
  """
  @spec prm_candidates(String.t(), String.t() | nil, keyword()) ::
          {:ok, [String.t(), ...]} | {:error, Error.t()}
  def prm_candidates(server_url, resource_metadata \\ nil, opts \\ [])

  def prm_candidates(server_url, resource_metadata, opts)
      when is_nil(resource_metadata) or is_binary(resource_metadata) do
    with {:ok, uri} <- URL.parse(server_url, opts) do
      origin = URL.origin(uri)
      query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query

      inserted =
        case URL.trimmed_path(uri) do
          "" -> origin <> @prm_path <> query
          path -> origin <> @prm_path <> path <> query
        end

      {:ok, Enum.uniq(List.wrap(resource_metadata) ++ [inserted, origin <> @prm_path])}
    end
  end

  @doc """
  The authorization-server metadata URLs to try for `issuer`, in order.

  The issuer must be an `https` URL without a query or fragment (RFC 8414
  §2). A terminating slash is removed before the well-known path is
  inserted (RFC 8414 §3.1), so `https://as.example/` has no path.

      iex> ConduitMcp.Client.OAuth.Discovery.as_metadata_candidates("https://auth.ex.com")
      {:ok,
       [
         "https://auth.ex.com/.well-known/oauth-authorization-server",
         "https://auth.ex.com/.well-known/openid-configuration"
       ]}
  """
  @spec as_metadata_candidates(String.t(), keyword()) ::
          {:ok, [String.t(), ...]} | {:error, Error.t()}
  def as_metadata_candidates(issuer, opts \\ []) do
    with {:ok, uri} <- parse_issuer(issuer, opts) do
      origin = URL.origin(uri)

      case URL.trimmed_path(uri) do
        "" ->
          {:ok, [origin <> @oauth_path, origin <> @oidc_path]}

        path ->
          {:ok,
           [
             origin <> @oauth_path <> path,
             origin <> @oidc_path <> path,
             origin <> path <> @oidc_path
           ]}
      end
    end
  end

  @doc """
  Validates decoded Protected Resource Metadata against the canonical server
  URI (from `ConduitMcp.Client.OAuth.Resource.canonical/2`) and returns it
  unchanged.

  Errors: `:invalid_metadata` (not an object; `authorization_servers` or
  `scopes_supported` not a list of strings; data names the field),
  `:resource_mismatch`, `:no_authorization_server`.
  """
  @spec validate_prm(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def validate_prm(%{} = prm, canonical_resource) when is_binary(canonical_resource) do
    cond do
      Map.get(prm, "resource") !== canonical_resource ->
        Error.error(:resource_mismatch)

      not string_list?(Map.get(prm, "authorization_servers", [])) ->
        Error.error(:invalid_metadata, %{field: "authorization_servers"})

      Map.get(prm, "authorization_servers", []) == [] ->
        Error.error(:no_authorization_server)

      not string_list?(Map.get(prm, "scopes_supported", [])) ->
        Error.error(:invalid_metadata, %{field: "scopes_supported"})

      true ->
        {:ok, prm}
    end
  end

  def validate_prm(_prm, _canonical_resource), do: Error.error(:invalid_metadata, %{field: nil})

  @doc """
  Chooses the authorization server from validated PRM: the first entry of
  `authorization_servers`.

  ## Options

    * `:expected_issuers` - when a list, the chosen issuer must be in it
      (exact string match), else `:issuer_not_allowed`. `nil` (default)
      accepts any.
  """
  @spec select_issuer(map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def select_issuer(prm, opts \\ [])

  def select_issuer(%{"authorization_servers" => [issuer | _]}, opts) when is_binary(issuer) do
    case Keyword.get(opts, :expected_issuers) do
      nil ->
        {:ok, issuer}

      allowed when is_list(allowed) ->
        if issuer in allowed, do: {:ok, issuer}, else: Error.error(:issuer_not_allowed)
    end
  end

  def select_issuer(_prm, _opts), do: Error.error(:no_authorization_server)

  @doc """
  Validates decoded authorization-server metadata fetched for `issuer` and
  returns it unchanged. See the moduledoc for the rules; they are checked in
  this order: object, `issuer`, S256, required endpoints, every endpoint.

  Errors: `:invalid_metadata` (data `%{field: name}`), `:issuer_mismatch`,
  `:pkce_unsupported`, `:insecure_endpoint` (data `%{field: name, scheme:
  scheme}`).

  ## Options

    * `:allow_insecure` - admit `http` endpoints on loopback hosts.
    * `:grant` - `:authorization_code` (default) or `:client_credentials`.
      A machine-to-machine client never sends the user to the
      authorization endpoint, so for `:client_credentials` neither `"S256"`
      nor `authorization_endpoint` is required; `token_endpoint` still is,
      and every endpoint present is still checked.
  """
  @spec validate_as_metadata(term(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def validate_as_metadata(metadata, issuer, opts \\ [])

  def validate_as_metadata(%{} = metadata, issuer, opts) when is_binary(issuer) do
    code_flow? = Keyword.get(opts, :grant, :authorization_code) == :authorization_code

    cond do
      Map.get(metadata, "issuer") !== issuer -> Error.error(:issuer_mismatch)
      code_flow? and not PKCE.s256_supported?(metadata) -> Error.error(:pkce_unsupported)
      true -> validate_endpoints(metadata, required_endpoints(code_flow?), opts)
    end
  end

  def validate_as_metadata(_metadata, _issuer, _opts),
    do: Error.error(:invalid_metadata, %{field: nil})

  defp required_endpoints(true), do: @required_endpoints
  defp required_endpoints(false), do: ["token_endpoint"]

  defp validate_endpoints(metadata, required, opts) do
    missing = Enum.find(required, &(not Map.has_key?(metadata, &1)))

    optional =
      metadata
      |> Map.keys()
      |> Enum.filter(&endpoint_field?/1)
      |> Enum.sort()

    fields = required ++ (optional -- required)

    if missing do
      Error.error(:invalid_metadata, %{field: missing})
    else
      Enum.reduce_while(fields, {:ok, metadata}, fn field, acc ->
        case validate_endpoint(Map.fetch!(metadata, field), field, opts) do
          :ok -> {:cont, acc}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp endpoint_field?("jwks_uri"), do: true
  defp endpoint_field?(field) when is_binary(field), do: String.ends_with?(field, "_endpoint")
  defp endpoint_field?(_field), do: false

  defp validate_endpoint(url, field, _opts) when not is_binary(url),
    do: Error.error(:invalid_metadata, %{field: field})

  defp validate_endpoint(url, field, opts) do
    case URL.parse(url, opts) do
      {:ok, %URI{fragment: nil}} -> :ok
      {:ok, %URI{}} -> Error.error(:invalid_metadata, %{field: field})
      {:error, %Error{reason: :insecure_url, data: scheme}} -> insecure(field, scheme)
      {:error, %Error{}} -> Error.error(:invalid_metadata, %{field: field})
    end
  end

  defp insecure(field, scheme),
    do: Error.error(:insecure_endpoint, %{field: field, scheme: scheme})

  defp parse_issuer(issuer, opts) do
    case URL.parse(issuer, opts) do
      {:ok, %URI{query: nil, fragment: nil} = uri} -> {:ok, uri}
      {:ok, %URI{}} -> Error.error(:invalid_url, :issuer_query_or_fragment)
      {:error, _} = error -> error
    end
  end

  defp string_list?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp string_list?(_other), do: false
end
