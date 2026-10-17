defmodule ConduitMcp.Client.OAuth.Error do
  @moduledoc """
  The error type of the OAuth 2.1 client (`ConduitMcp.Client.OAuth.*`).

  Every OAuth helper that can fail returns `{:error, %ConduitMcp.Client.OAuth.Error{}}`.
  Match on `:reason`, which is one of the closed set in `reasons/0`.

  ## Fields

    * `:reason` - an atom from `reasons/0`.
    * `:data` - optional, non-secret context: the metadata field that failed
      (`%{field: "token_endpoint", scheme: "javascript"}`), a parser detail
      atom, or, for authorization-response errors, the server's `error`,
      `error_description` and `error_uri` strings exactly as received. It may
      hold server-supplied text, so `message/1` never renders it.

  ## Secrets

  No OAuth helper ever puts a token, refresh token, authorization code,
  `state` or PKCE verifier into an error, and `message/1` renders only the
  reason and a fixed description. The message is safe to log.

  ## Reasons

  Parsing and URL rules (`Challenge`, `Resource`, `Discovery`, `Pending`):

    * `:invalid_challenge` - a `WWW-Authenticate` value is malformed or over a
      limit; `:data` is the detail atom (see `ConduitMcp.Client.OAuth.Challenge`).
    * `:invalid_url` - a URL does not parse, has no host, carries user info,
      or (for an issuer) has a query or fragment; `:data` names the problem.
    * `:insecure_url` - a URL that must be `https` is not (plain `http` is
      only admitted for loopback hosts, and for anything but a redirect URI
      only behind `allow_insecure: true`).

  Discovery and metadata validation (`Discovery`, `PKCE`):

    * `:resource_mismatch` - Protected Resource Metadata `resource` is not
      exactly the canonical server URI (RFC 9728 §3.3).
    * `:no_authorization_server` - the PRM lists no authorization server.
    * `:issuer_not_allowed` - the chosen authorization server is not in the
      configured `expected_issuers` allowlist.
    * `:invalid_metadata` - PRM or authorization-server metadata is not an
      object or a field has the wrong type; `:data` names the field.
    * `:issuer_mismatch` - authorization-server metadata `issuer` is not
      exactly the issuer the metadata URL was built from (RFC 8414 §3.3).
    * `:pkce_unsupported` - `code_challenge_methods_supported` is absent or
      lacks `"S256"`.
    * `:insecure_endpoint` - an endpoint in the authorization-server metadata
      is not `https` (this is also how `javascript:`, `file:`, `data:` and
      every other scheme is refused); `:data` names the field and scheme.

  Authorization response (`Callback`):

    * `:invalid_state` - `state` is missing or does not match.
    * `:principal_mismatch` - the callback is completed under a different
      principal than the one that started the flow.
    * `:state_expired` - the pending authorization outlived its TTL.
    * `:iss_mismatch` - the response `iss` is not exactly the recorded issuer
      (RFC 9207 §2.4). Nothing else from the response is surfaced.
    * `:iss_missing` - the authorization server advertises
      `authorization_response_iss_parameter_supported` but sent no `iss`.
    * `:missing_code` - neither `code` nor `error` is present.
    * `:invalid_pending` - a stored pending authorization could not be
      restored by `ConduitMcp.Client.OAuth.Pending.from_map/1`; `:data`
      names the field.
    * `:access_denied`, `:invalid_request`, `:unauthorized_client`,
      `:unsupported_response_type`, `:invalid_scope`, `:server_error`,
      `:temporarily_unavailable` - the authorization server returned that
      RFC 6749 §4.1.2.1 `error` code.
    * `:authorization_error` - the authorization server returned any other
      `error` code; it is in `:data` as a string, never as an atom.

  Runtime (produced by the HTTP-layer OAuth flow, defined here so the set is
  closed in one place):

    * `:authorization_required` - interactive authorization is needed.
    * `:no_protected_resource_metadata` - every PRM candidate URL failed.
    * `:no_authorization_server_metadata` - every AS-metadata candidate failed.
    * `:authorization_server_changed` - pre-registered credentials are bound
      to a different issuer than the one the server now names.
    * `:no_registration_method` - no pre-registered client, CIMD or DCR applies.
    * `:registration_failed` - dynamic client registration was refused.
    * `:invalid_grant` - the token endpoint rejected the code or refresh token.
    * `:token_request_failed` - the token endpoint failed otherwise.
    * `:step_up_limit` - the step-up attempt limit for a resource and scope set
      was reached (see `ConduitMcp.Client.OAuth.Scopes.step_up_allowed?/4`).
    * `:url_blocked` - `ConduitMcp.Client.URLPolicy` refused a server-supplied
      URL before any connection was made (a private, loopback or otherwise
      internal address, or an unresolvable host); `:data` is the policy's
      reason.
    * `:client_secret_unavailable` - a client secret configured as
      `{:system, "VAR"}` names an unset environment variable; `:data` is the
      variable name.
  """

  @descriptions [
    invalid_challenge: "malformed WWW-Authenticate challenge",
    invalid_url: "invalid URL",
    insecure_url: "URL must use https",
    resource_mismatch: "protected resource metadata names a different resource",
    no_authorization_server: "protected resource metadata lists no authorization server",
    issuer_not_allowed: "authorization server is not in expected_issuers",
    invalid_metadata: "malformed OAuth metadata",
    issuer_mismatch: "authorization server metadata names a different issuer",
    pkce_unsupported: "authorization server does not support PKCE S256",
    insecure_endpoint: "authorization server endpoint must use https",
    invalid_state: "authorization response state is missing or does not match",
    principal_mismatch: "authorization response belongs to a different principal",
    state_expired: "pending authorization expired",
    iss_mismatch: "authorization response iss does not match the issuer",
    iss_missing: "authorization response iss is required but missing",
    missing_code: "authorization response has no code",
    invalid_pending: "malformed pending authorization",
    access_denied: "authorization server returned access_denied",
    invalid_request: "authorization server returned invalid_request",
    unauthorized_client: "authorization server returned unauthorized_client",
    unsupported_response_type: "authorization server returned unsupported_response_type",
    invalid_scope: "authorization server returned invalid_scope",
    server_error: "authorization server returned server_error",
    temporarily_unavailable: "authorization server returned temporarily_unavailable",
    authorization_error: "authorization server returned an error",
    authorization_required: "authorization required",
    no_protected_resource_metadata: "no protected resource metadata found",
    no_authorization_server_metadata: "no authorization server metadata found",
    authorization_server_changed: "credentials are bound to a different authorization server",
    no_registration_method: "no client registration method available",
    registration_failed: "client registration failed",
    invalid_grant: "authorization grant or refresh token rejected",
    token_request_failed: "token request failed",
    step_up_limit: "step-up authorization attempt limit reached",
    url_blocked: "URL refused by the URL policy",
    client_secret_unavailable: "the configured client secret is not set"
  ]

  @reasons Keyword.keys(@descriptions)

  @type reason ::
          :invalid_challenge
          | :invalid_url
          | :insecure_url
          | :resource_mismatch
          | :no_authorization_server
          | :issuer_not_allowed
          | :invalid_metadata
          | :issuer_mismatch
          | :pkce_unsupported
          | :insecure_endpoint
          | :invalid_state
          | :principal_mismatch
          | :state_expired
          | :iss_mismatch
          | :iss_missing
          | :missing_code
          | :invalid_pending
          | :access_denied
          | :invalid_request
          | :unauthorized_client
          | :unsupported_response_type
          | :invalid_scope
          | :server_error
          | :temporarily_unavailable
          | :authorization_error
          | :authorization_required
          | :no_protected_resource_metadata
          | :no_authorization_server_metadata
          | :authorization_server_changed
          | :no_registration_method
          | :registration_failed
          | :invalid_grant
          | :token_request_failed
          | :step_up_limit
          | :url_blocked
          | :client_secret_unavailable

  @type t :: %__MODULE__{reason: reason(), data: term()}

  defexception [:reason, :data]

  @doc "Every valid `:reason`, in documentation order."
  @spec reasons() :: [reason(), ...]
  def reasons, do: @reasons

  @doc """
  Builds an error, raising `ArgumentError` when `reason` is not in `reasons/0`.

      iex> ConduitMcp.Client.OAuth.Error.new(:pkce_unsupported).reason
      :pkce_unsupported
  """
  @spec new(reason(), term()) :: t()
  def new(reason, data \\ nil)

  def new(reason, data) when reason in @reasons, do: %__MODULE__{reason: reason, data: data}

  def new(reason, _data),
    do: raise(ArgumentError, "unknown ConduitMcp.Client.OAuth.Error reason: #{inspect(reason)}")

  @doc "`{:error, new(reason, data)}`."
  @spec error(reason(), term()) :: {:error, t()}
  def error(reason, data \\ nil), do: {:error, new(reason, data)}

  @impl true
  def message(%__MODULE__{reason: reason}) when reason in @reasons,
    do: "OAuth error (#{reason}): #{Keyword.fetch!(@descriptions, reason)}"

  def message(%__MODULE__{}), do: "OAuth error"
end
