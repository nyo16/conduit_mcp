defmodule ConduitMcp.Plugs.OAuth.Claims do
  @moduledoc false
  # The OAuth plug's own claim checks, after Joken's signature and default
  # claim validation. Joken's default claims already reject a future or
  # malformed `nbf` and a wrong `iss`, so those clauses are a second line that
  # only a direct call reaches. Pure map checks: compiled without Joken.

  @spec validate(map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def validate(claims, issuer, audience) do
    with :ok <- validate_exp(claims),
         :ok <- validate_nbf(claims),
         :ok <- validate_issuer(claims, issuer),
         :ok <- validate_audience(claims, audience) do
      {:ok, claims}
    end
  end

  # `Joken.Config.default_claims(default_exp: 3600)` only affects token
  # *generation*. Validation folds over the claims the token actually
  # carries, so a token with no `exp` was never checked against anything
  # and was accepted forever. `exp` is mandatory here.
  defp validate_exp(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp validate_exp(_claims), do: {:error, :expired}

  # `nbf` is optional, but a present one must hold — and a malformed one
  # must not be silently ignored.
  defp validate_nbf(%{"nbf" => nbf}) when is_integer(nbf) do
    if nbf <= System.system_time(:second), do: :ok, else: {:error, :not_yet_valid}
  end

  defp validate_nbf(%{"nbf" => _malformed}), do: {:error, :not_yet_valid}
  defp validate_nbf(_claims), do: :ok

  defp validate_issuer(claims, expected_issuer) do
    case Map.get(claims, "iss") do
      ^expected_issuer -> :ok
      _ -> {:error, :invalid_issuer}
    end
  end

  defp validate_audience(claims, expected_audience) do
    case Map.get(claims, "aud") do
      ^expected_audience ->
        :ok

      aud when is_list(aud) ->
        if expected_audience in aud, do: :ok, else: {:error, :invalid_audience}

      _ ->
        {:error, :invalid_audience}
    end
  end
end
