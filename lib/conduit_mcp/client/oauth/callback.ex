defmodule ConduitMcp.Client.OAuth.Callback do
  @moduledoc """
  Validates an authorization response (the query parameters delivered to the
  redirect URI) against its `ConduitMcp.Client.OAuth.Pending`, before the
  code goes anywhere near a token endpoint.

  `validate/3` runs these checks in order and stops at the first failure:

    1. **`state`** equals the pending state, compared in constant time with
       `Plug.Crypto.secure_compare/2`; missing or different ⇒ `:invalid_state`.
    2. **Principal** - the `:principal` the callback is completed under equals
       (`===`) the one the flow was started with ⇒ else `:principal_mismatch`.
    3. **Expiry** - `now` is before `expires_at` ⇒ else `:state_expired`.
    4. **`iss`** (RFC 9207 §2.4, OA-3), by exact string comparison with the
       recorded issuer and no normalization of case, slashes or ports:

       | `iss` in the response | AS advertises `iss` support | Result |
       |---|---|---|
       | present, equal | either | continue |
       | present, different | either | `:iss_mismatch` |
       | absent | `true` | `:iss_missing` |
       | absent | `false` / not advertised | continue |

       A present `iss` is compared even when the authorization server never
       advertised the parameter. A key with a `nil` value counts as absent.
    5. **`error`** - an error response becomes the matching typed reason
       (`:access_denied`, ... or `:authorization_error` for an unknown code),
       with the server's `error`, `error_description` and `error_uri` strings
       in `:data`.
    6. **`code`** - returned wrapped in `ConduitMcp.Client.Secret`; absent ⇒
       `:missing_code`.

  Steps 1-4 come first so that a response from the wrong party, or for the
  wrong flow, surfaces nothing it carries: on any of those failures the
  error's `:data` is `nil`, and in particular a mismatched response's
  `error_description` is never passed through.

  ## Replay

  `validate/3` is pure, so it accepts the same `Pending` and parameters as
  often as it is called. Single use of `state` is enforced by the host's
  store, which must delete the pending entry when it is looked up (see
  `ConduitMcp.Client.OAuth.Pending`).
  """

  alias ConduitMcp.Client.OAuth.{Error, Pending}
  alias ConduitMcp.Client.Secret

  # RFC 6749 §4.1.2.1 error codes; anything else is `:authorization_error`.
  @error_codes %{
    "invalid_request" => :invalid_request,
    "unauthorized_client" => :unauthorized_client,
    "access_denied" => :access_denied,
    "unsupported_response_type" => :unsupported_response_type,
    "invalid_scope" => :invalid_scope,
    "server_error" => :server_error,
    "temporarily_unavailable" => :temporarily_unavailable
  }

  @error_fields ["error", "error_description", "error_uri"]

  @doc """
  Validates `params` (string-keyed, as decoded from the redirect query) for
  `pending`. See the moduledoc for the order of checks.

  ## Options

    * `:principal` - the host identity completing the flow (default `nil`;
      must equal the pending principal).
    * `:now` - current Unix time in seconds (default: the system clock).
  """
  @spec validate(Pending.t(), map(), keyword()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def validate(%Pending{} = pending, params, opts \\ []) when is_map(params) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with :ok <- check_state(pending, Map.get(params, "state")),
         :ok <- check_principal(pending, Keyword.get(opts, :principal)),
         :ok <- check_expiry(pending, now),
         :ok <- check_iss(pending, Map.get(params, "iss")) do
      response(params)
    end
  end

  defp check_state(%Pending{state: state}, given) when is_binary(given) do
    if Plug.Crypto.secure_compare(given, Secret.expose(state)),
      do: :ok,
      else: Error.error(:invalid_state)
  end

  defp check_state(_pending, _given), do: Error.error(:invalid_state)

  defp check_principal(%Pending{principal: principal}, principal), do: :ok
  defp check_principal(_pending, _principal), do: Error.error(:principal_mismatch)

  defp check_expiry(pending, now) do
    if Pending.expired?(pending, now), do: Error.error(:state_expired), else: :ok
  end

  defp check_iss(%Pending{issuer: issuer}, issuer), do: :ok
  defp check_iss(%Pending{iss_parameter_supported: true}, nil), do: Error.error(:iss_missing)
  defp check_iss(%Pending{}, nil), do: :ok
  defp check_iss(%Pending{}, _other), do: Error.error(:iss_mismatch)

  defp response(%{"error" => code} = params) when is_binary(code) do
    data =
      for {key, value} <- Map.take(params, @error_fields),
          is_binary(value),
          into: %{},
          do: {key, value}

    Error.error(Map.get(@error_codes, code, :authorization_error), data)
  end

  defp response(%{"code" => code}) when is_binary(code) and code != "",
    do: {:ok, Secret.new(code)}

  defp response(_params), do: Error.error(:missing_code)
end
