if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.Discovery.Fetch do
    @moduledoc """
    The network side of authorization-server discovery: fetches the
    candidates `ConduitMcp.Client.OAuth.Discovery` lists, in order, and
    validates what comes back with its pure validators. Compiled only with
    the optional `:finch` dependency.

    `discover/2`, for the MCP server of a `ConduitMcp.Client.OAuth.Config`:

      1. **Protected Resource Metadata** (RFC 9728) - the challenge's
         `resource_metadata` URL, then the path-inserted, then the root
         well-known URL. A candidate that fails (any non-200 status, a
         redirect, a network error, a body that is not a JSON object) is
         skipped; the first document is validated, and a document naming
         another `resource` is refused (`:resource_mismatch`) rather than
         skipped. None ⇒ `:no_protected_resource_metadata`.
      2. **The authorization server** - the first of `authorization_servers`,
         which must be in `:expected_issuers` when that is set.
      3. **Authorization-server metadata** (RFC 8414 / OpenID Connect
         Discovery) - OAuth path-insert, OIDC path-insert, OIDC path-append
         (without an issuer path: OAuth, then OIDC). The first document is
         validated: exact `issuer`, `S256`, `https` endpoints (OA-1, OA-4,
         OA-7). None ⇒ `:no_authorization_server_metadata`.

    Every request goes through the client's OAuth HTTP layer: no
    `Authorization` header, no redirects, a capped body, and every URL
    checked by `ConduitMcp.Client.URLPolicy` `:public_only` and pinned to
    the vetted address (HT-6) unless `allow_insecure_oauth: true` admits a
    plain-`http` loopback URL (development and tests).
    """

    alias ConduitMcp.Client.OAuth.{Challenge, Config, Discovery, Error, HTTP, Resource}
    alias ConduitMcp.Client.OAuth.Telemetry

    @typedoc """
    What discovery found: the canonical `resource`, the validated PRM, the
    chosen `issuer` and its validated metadata. No secrets.
    """
    @type context :: %{
            resource: String.t(),
            prm: map(),
            issuer: String.t(),
            metadata: map()
          }

    @doc """
    Discovers the authorization server of `config`'s MCP server, using the
    `resource_metadata` of `challenge` (a Bearer
    `ConduitMcp.Client.OAuth.Challenge`) when it has one.
    """
    @spec discover(Config.t(), Challenge.t() | nil) :: {:ok, context()} | {:error, Error.t()}
    def discover(%Config{} = config, challenge \\ nil) do
      Telemetry.span(:discovery, Telemetry.base(config), fn ->
        result =
          with {:ok, resource} <- Resource.canonical(config.server_url, Config.url_opts(config)),
               {:ok, prm} <- fetch_prm(config, resource, resource_metadata(challenge)),
               {:ok, issuer} <-
                 Discovery.select_issuer(prm, expected_issuers: config.expected_issuers),
               {:ok, metadata} <- fetch_as_metadata(config, issuer) do
            {:ok, %{resource: resource, prm: prm, issuer: issuer, metadata: metadata}}
          end

        {result, %{}}
      end)
    end

    defp resource_metadata(%Challenge{} = challenge), do: Challenge.resource_metadata(challenge)
    defp resource_metadata(nil), do: nil

    @doc """
    Fetches and validates the Protected Resource Metadata for the canonical
    `resource` (see the moduledoc for the order).
    """
    @spec fetch_prm(Config.t(), String.t(), String.t() | nil) ::
            {:ok, map()} | {:error, Error.t()}
    def fetch_prm(%Config{} = config, resource, resource_metadata) do
      with {:ok, candidates} <-
             Discovery.prm_candidates(
               config.server_url,
               resource_metadata,
               Config.url_opts(config)
             ) do
        first_document(config, candidates, :no_protected_resource_metadata, fn document ->
          Discovery.validate_prm(document, resource)
        end)
      end
    end

    @doc """
    Fetches and validates the metadata of the authorization server `issuer`
    (see the moduledoc for the order).
    """
    @spec fetch_as_metadata(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
    def fetch_as_metadata(%Config{} = config, issuer) do
      opts = Config.url_opts(config) ++ [grant: config.grant]

      with {:ok, candidates} <- Discovery.as_metadata_candidates(issuer, Config.url_opts(config)) do
        first_document(config, candidates, :no_authorization_server_metadata, fn document ->
          Discovery.validate_as_metadata(document, issuer, opts)
        end)
      end
    end

    # The first candidate answering 200 with a JSON object is validated
    # (and its verdict final); any other outcome tries the next. A URL the
    # policy refuses is skipped too, but reported if nothing else answered.
    defp first_document(config, candidates, none, validate) do
      ctx = Config.http(config)

      Enum.reduce_while(candidates, Error.error(none), fn url, acc ->
        with {:ok, %{status: 200} = response} <- HTTP.get(url, ctx),
             {:ok, document} <- HTTP.json(response) do
          {:halt, validate.(document)}
        else
          {:error, {:url_blocked, reason}} -> {:cont, blocked(acc, reason)}
          _skip -> {:cont, acc}
        end
      end)
    end

    defp blocked({:error, %Error{reason: reason}}, policy_reason)
         when reason in [:no_protected_resource_metadata, :no_authorization_server_metadata],
         do: Error.error(:url_blocked, policy_reason)

    defp blocked(acc, _policy_reason), do: acc
  end
end
