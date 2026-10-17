defmodule ConduitMcp.Client.OAuth.Pending do
  @moduledoc """
  An authorization-code flow between the authorization request and the
  callback: everything the client must remember to validate the response
  and redeem the code.

  `new/1` generates the two secrets of the flow: a `state` of 32 random bytes
  (base64url, 43 characters) and a PKCE code verifier (`ConduitMcp.Client.OAuth.PKCE.verifier/0`),
  both wrapped in `ConduitMcp.Client.Secret`, and stamps a 10 minute TTL. It
  records the issuer the flow was started against (for the RFC 9207 `iss`
  check), the canonical resource, the redirect URI (the token request must
  repeat it exactly), the requested scopes and the principal - the end-user
  or session identity of the host - that the flow is bound to.

  ## The host stores it

  `Pending` is plain data the host keeps between the redirect and the
  callback: in its session store, a database row, or an encrypted cookie.
  `to_map/1` gives a string-keyed map of strings, integers, booleans and
  lists (plus the principal as given) for that; `from_map/1` validates and
  restores it. Restore the struct before calling
  `ConduitMcp.Client.OAuth.Callback.validate/3`.

  **The map holds secrets in plain text** (`state` and `code_verifier`).
  Keep it server-side, or encrypt it (for example with
  `Plug.Crypto.encrypt/4`); signing alone does not hide it. `inspect/1` of
  the struct shows both as `#Secret<redacted>`.

  ## Single use is the host's job

  `state` must be usable exactly once (OA-2). Because `Pending` is data, the
  library cannot see a second copy being presented, so a replayed callback
  is rejected only if the host's store enforces it: **look the pending entry
  up by `state` and delete it in the same step, before validating, and on
  failure as well as on success.** `ConduitMcp.Client.OAuth.Callback.validate/3`
  checks the state value, principal binding, expiry and `iss`; it does not
  and cannot check consumption.

  ## Serialization of the principal

  The principal is stored in `to_map/1` exactly as given. A host that
  JSON-encodes the map should use a string principal.
  """

  alias ConduitMcp.Client.OAuth.{Error, PKCE, URL}
  alias ConduitMcp.Client.Secret

  @default_ttl 600
  @version 1

  @enforce_keys [:state, :verifier, :redirect_uri, :issuer, :resource, :created_at, :expires_at]
  defstruct [
    :state,
    :verifier,
    :redirect_uri,
    :issuer,
    :resource,
    :created_at,
    :expires_at,
    scopes: [],
    principal: nil,
    iss_parameter_supported: false,
    client_id: nil,
    token_endpoint: nil
  ]

  @typedoc """
  * `:state`, `:verifier` - the flow's secrets.
  * `:redirect_uri` - sent in the authorization request; must be repeated in
    the token request.
  * `:issuer` - the authorization server's `issuer`, as validated.
  * `:resource` - the canonical resource URI (RFC 8707 `resource`).
  * `:scopes` - the requested scopes.
  * `:principal` - the host identity the flow is bound to (`nil` if none).
  * `:iss_parameter_supported` - the AS metadata's
    `authorization_response_iss_parameter_supported` was `true`.
  * `:client_id`, `:token_endpoint` - the client identity and token endpoint
    the flow was started with, so the code is redeemed at the same
    authorization server (`nil` when not recorded).
  * `:created_at`, `:expires_at` - Unix seconds.
  """
  @type t :: %__MODULE__{
          state: Secret.t(),
          verifier: Secret.t(),
          redirect_uri: String.t(),
          issuer: String.t(),
          resource: String.t(),
          scopes: [String.t()],
          principal: term(),
          iss_parameter_supported: boolean(),
          client_id: String.t() | nil,
          token_endpoint: String.t() | nil,
          created_at: integer(),
          expires_at: integer()
        }

  @schema NimbleOptions.new!(
            redirect_uri: [
              type: {:custom, __MODULE__, :validate_redirect_uri, []},
              required: true,
              doc: "An `https` URL, or `http` on a loopback host (RFC 8252 §7.3); no fragment."
            ],
            issuer: [type: :string, required: true, doc: "The validated `issuer`."],
            resource: [type: :string, required: true, doc: "The canonical resource URI."],
            scopes: [type: {:list, :string}, default: [], doc: "The requested scopes."],
            principal: [type: :any, default: nil, doc: "The host identity to bind the flow to."],
            iss_parameter_supported: [
              type: :boolean,
              default: false,
              doc: "The AS advertises `authorization_response_iss_parameter_supported: true`."
            ],
            client_id: [type: {:or, [:string, nil]}, default: nil, doc: "The client id used."],
            token_endpoint: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: "The validated token endpoint."
            ],
            ttl: [type: :pos_integer, default: @default_ttl, doc: "Lifetime in seconds."],
            now: [
              type: :integer,
              doc: "Current Unix time in seconds (default: the system clock)."
            ]
          )

  @doc """
  Starts a pending authorization with a fresh `state` and code verifier.

  Raises `NimbleOptions.ValidationError` on invalid options.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    %__MODULE__{
      state: Secret.new(random_state()),
      verifier: Secret.new(PKCE.verifier()),
      redirect_uri: opts[:redirect_uri],
      issuer: opts[:issuer],
      resource: opts[:resource],
      scopes: opts[:scopes],
      principal: opts[:principal],
      iss_parameter_supported: opts[:iss_parameter_supported],
      client_id: opts[:client_id],
      token_endpoint: opts[:token_endpoint],
      created_at: now,
      expires_at: now + opts[:ttl]
    }
  end

  @doc "The PKCE `S256` code challenge for the pending verifier."
  @spec code_challenge(t()) :: String.t()
  def code_challenge(%__MODULE__{verifier: verifier}), do: PKCE.challenge(verifier)

  @doc "Whether the pending authorization has expired at Unix time `now`."
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now) when is_integer(now),
    do: now >= expires_at

  @doc """
  The pending authorization as a string-keyed map for host storage. It
  contains `state` and `code_verifier` in plain text; see the moduledoc.
  """
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = pending) do
    %{
      "v" => @version,
      "state" => Secret.expose(pending.state),
      "code_verifier" => Secret.expose(pending.verifier),
      "redirect_uri" => pending.redirect_uri,
      "issuer" => pending.issuer,
      "resource" => pending.resource,
      "scopes" => pending.scopes,
      "principal" => pending.principal,
      "iss_parameter_supported" => pending.iss_parameter_supported,
      "client_id" => pending.client_id,
      "token_endpoint" => pending.token_endpoint,
      "created_at" => pending.created_at,
      "expires_at" => pending.expires_at
    }
  end

  @doc """
  Restores a map from `to_map/1`. Every field is type-checked; a missing or
  malformed one gives `:invalid_pending` with `%{field: name}` as data (the
  value itself is never put in the error). The expiry is not checked here.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"v" => @version} = map) do
    with {:ok, state} <- fetch(map, "state", &(is_binary(&1) and &1 != "")),
         {:ok, verifier} <- fetch(map, "code_verifier", &PKCE.valid_verifier?/1),
         {:ok, redirect_uri} <- fetch(map, "redirect_uri", &valid_redirect_uri?/1),
         {:ok, issuer} <- fetch(map, "issuer", &is_binary/1),
         {:ok, resource} <- fetch(map, "resource", &is_binary/1),
         {:ok, scopes} <- fetch(map, "scopes", &string_list?/1),
         {:ok, iss?} <- fetch(map, "iss_parameter_supported", &is_boolean/1),
         {:ok, client_id} <- fetch(map, "client_id", &nil_or_string?/1),
         {:ok, token_endpoint} <- fetch(map, "token_endpoint", &nil_or_string?/1),
         {:ok, created_at} <- fetch(map, "created_at", &is_integer/1),
         {:ok, expires_at} <- fetch(map, "expires_at", &(is_integer(&1) and &1 >= created_at)) do
      {:ok,
       %__MODULE__{
         state: Secret.new(state),
         verifier: Secret.new(verifier),
         redirect_uri: redirect_uri,
         issuer: issuer,
         resource: resource,
         scopes: scopes,
         principal: Map.get(map, "principal"),
         iss_parameter_supported: iss?,
         client_id: client_id,
         token_endpoint: token_endpoint,
         created_at: created_at,
         expires_at: expires_at
       }}
    end
  end

  def from_map(_map), do: Error.error(:invalid_pending, %{field: "v"})

  @doc false
  # NimbleOptions `{:custom, ...}` validator for `:redirect_uri`.
  @spec validate_redirect_uri(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_redirect_uri(value) do
    if valid_redirect_uri?(value),
      do: {:ok, value},
      else: {:error, "expected an https URL, or http on a loopback host, without a fragment"}
  end

  # Redirect URIs may be plain `http` on loopback without any opt-in
  # (RFC 8252 §7.3, MCP authorization spec); the fragment is forbidden by
  # RFC 6749 §3.1.2.
  defp valid_redirect_uri?(value) do
    match?({:ok, %URI{fragment: nil}}, URL.parse(value, allow_insecure: true))
  end

  defp random_state, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp fetch(map, key, valid?) do
    with {:ok, value} <- Map.fetch(map, key), true <- valid?.(value) do
      {:ok, value}
    else
      _ -> Error.error(:invalid_pending, %{field: key})
    end
  end

  defp nil_or_string?(value), do: is_nil(value) or is_binary(value)

  defp string_list?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp string_list?(_other), do: false
end
