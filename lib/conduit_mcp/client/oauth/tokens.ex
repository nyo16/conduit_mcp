defmodule ConduitMcp.Client.OAuth.Tokens do
  @moduledoc """
  The tokens the client holds for one `{principal, issuer, resource}`.

  `access_token` and `refresh_token` are `ConduitMcp.Client.Secret`s, so
  `inspect/1`, logs and crash reports show `#Secret<redacted>`; the bearer
  is exposed only where the `Authorization` header is built. `expires_at` is
  Unix seconds computed locally from `expires_in` (`nil` when the server gave
  no lifetime).

      iex> tokens = ConduitMcp.Client.OAuth.Tokens.new(access_token: "at", expires_at: 1_000)
      iex> inspect(tokens) =~ "at\\""
      false
      iex> ConduitMcp.Client.OAuth.Tokens.expired?(tokens, 960, 30)
      false
      iex> ConduitMcp.Client.OAuth.Tokens.expired?(tokens, 970, 30)
      true
  """

  alias ConduitMcp.Client.Secret

  @enforce_keys [:access_token]
  defstruct access_token: nil,
            refresh_token: nil,
            expires_at: nil,
            scopes: [],
            token_type: "Bearer"

  @type t :: %__MODULE__{
          access_token: Secret.t(),
          refresh_token: Secret.t() | nil,
          expires_at: integer() | nil,
          scopes: [String.t()],
          token_type: String.t()
        }

  @doc """
  Builds tokens from `fields`, wrapping `:access_token` and `:refresh_token`
  in `ConduitMcp.Client.Secret` (values already wrapped are kept).

  Raises `ArgumentError` when `:access_token` is missing or a field has the
  wrong type, and `KeyError` on an unknown field.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    tokens = struct!(__MODULE__, fields)

    if not valid?(tokens),
      do: raise(ArgumentError, "invalid ConduitMcp.Client.OAuth.Tokens fields")

    %{
      tokens
      | access_token: Secret.new(tokens.access_token),
        refresh_token: tokens.refresh_token && Secret.new(tokens.refresh_token)
    }
  end

  @doc """
  Whether the access token is expired, or expires within `skew_seconds`, at
  Unix time `now`: `now + skew_seconds >= expires_at`. Tokens without
  `expires_at` never expire by time (a 401 still triggers a refresh).
  """
  @spec expired?(t(), integer(), non_neg_integer()) :: boolean()
  def expired?(tokens, now, skew_seconds \\ 0)
  def expired?(%__MODULE__{expires_at: nil}, _now, _skew_seconds), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now, skew_seconds)
      when is_integer(now) and is_integer(skew_seconds) and skew_seconds >= 0,
      do: now + skew_seconds >= expires_at

  defp valid?(%__MODULE__{} = tokens) do
    valid_token?(tokens.access_token) and
      (is_nil(tokens.refresh_token) or valid_token?(tokens.refresh_token)) and
      (is_nil(tokens.expires_at) or is_integer(tokens.expires_at)) and
      is_list(tokens.scopes) and Enum.all?(tokens.scopes, &is_binary/1) and
      is_binary(tokens.token_type)
  end

  defp valid_token?(token) do
    token = if Secret.secret?(token), do: Secret.expose(token), else: token
    is_binary(token) and token != ""
  end
end
