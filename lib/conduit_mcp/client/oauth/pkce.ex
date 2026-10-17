defmodule ConduitMcp.Client.OAuth.PKCE do
  @moduledoc """
  Proof Key for Code Exchange (RFC 7636), `S256` only.

  The client never sends the `plain` method: an authorization server that
  does not advertise `"S256"` in `code_challenge_methods_supported` (or omits
  the field) is refused before any authorization or token request (OA-1).

      iex> ConduitMcp.Client.OAuth.PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  """

  alias ConduitMcp.Client.OAuth.Error
  alias ConduitMcp.Client.Secret

  @method "S256"

  @doc """
  A fresh code verifier: 32 bytes from `:crypto.strong_rand_bytes/1`,
  base64url-encoded without padding (43 characters, RFC 7636 §4.1).

  The verifier is a secret; wrap it in `ConduitMcp.Client.Secret` wherever it
  is held (as `ConduitMcp.Client.OAuth.Pending` does).
  """
  @spec verifier() :: String.t()
  def verifier, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  The `S256` code challenge for `verifier` (a string or a `Secret` wrapping
  one): `BASE64URL(SHA256(ASCII(verifier)))` without padding (RFC 7636 §4.2).

  Raises `ArgumentError` unless `verifier` is 43–128 characters of
  `[A-Za-z0-9-._~]` (RFC 7636 §4.1).
  """
  @spec challenge(String.t() | Secret.t()) :: String.t()
  def challenge(verifier) do
    verifier = if Secret.secret?(verifier), do: Secret.expose(verifier), else: verifier

    if valid_verifier?(verifier) do
      :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    else
      raise ArgumentError, "invalid PKCE code verifier (RFC 7636 §4.1)"
    end
  end

  @doc "The only `code_challenge_method` the client sends: `\"S256\"`."
  @spec method() :: String.t()
  def method, do: @method

  @doc """
  Whether `verifier` is a syntactically valid RFC 7636 §4.1 code verifier.
  """
  @spec valid_verifier?(term()) :: boolean()
  def valid_verifier?(verifier) when is_binary(verifier) and byte_size(verifier) in 43..128,
    do: verifier |> :binary.bin_to_list() |> Enum.all?(&unreserved?/1)

  def valid_verifier?(_verifier), do: false

  @doc """
  Whether decoded authorization-server `metadata` lists `"S256"` in
  `code_challenge_methods_supported`. The method name is compared exactly
  (it is case-sensitive); a missing or malformed field means `false`.

      iex> ConduitMcp.Client.OAuth.PKCE.s256_supported?(%{"code_challenge_methods_supported" => ["plain", "S256"]})
      true
      iex> ConduitMcp.Client.OAuth.PKCE.s256_supported?(%{"code_challenge_methods_supported" => ["plain"]})
      false
      iex> ConduitMcp.Client.OAuth.PKCE.s256_supported?(%{})
      false
  """
  @spec s256_supported?(map()) :: boolean()
  def s256_supported?(%{"code_challenge_methods_supported" => methods}) when is_list(methods),
    do: @method in methods

  def s256_supported?(_metadata), do: false

  @doc """
  Returns `:ok` when `s256_supported?/1` holds, else raises a
  `ConduitMcp.Client.OAuth.Error` with reason `:pkce_unsupported`.
  """
  @spec ensure_s256!(map()) :: :ok
  def ensure_s256!(metadata) do
    if s256_supported?(metadata), do: :ok, else: raise(Error.new(:pkce_unsupported))
  end

  defp unreserved?(c) when c in ?A..?Z or c in ?a..?z or c in ?0..?9, do: true
  defp unreserved?(c), do: c in [?-, ?., ?_, ?~]
end
