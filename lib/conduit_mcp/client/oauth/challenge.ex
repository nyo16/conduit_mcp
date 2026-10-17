defmodule ConduitMcp.Client.OAuth.Challenge do
  @moduledoc """
  Parses `WWW-Authenticate` header values (RFC 9110 §11.6.1, RFC 6750 §3) and
  reads the Bearer challenge an MCP server sends with a 401 or 403.

      iex> {:ok, [challenge]} =
      ...>   ConduitMcp.Client.OAuth.Challenge.parse(
      ...>     ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read files:write")
      ...>   )
      iex> ConduitMcp.Client.OAuth.Challenge.scopes(challenge)
      ["files:read", "files:write"]

  ## Grammar

      WWW-Authenticate = #challenge
      challenge        = auth-scheme [ 1*SP ( token68 / #auth-param ) ]
      auth-param       = token BWS "=" BWS ( token / quoted-string )

  The parser is a hand-written recursive descent over the bytes:

    * One header value may hold several challenges, and `parse/1` also takes
      a list of values (one per header line); the challenges are returned in
      order. Empty list elements (`, ,`) are skipped (RFC 9110 §5.6.1).
    * A comma separates both challenges and parameters. After a comma, the
      next element is a parameter when it starts with `token BWS "="`, and a
      new challenge otherwise.
    * After the scheme, a run of token68 characters (optionally ending in
      `=`s) followed by the end of the value or a comma is a token68
      (`Basic dXNlcjpwYXNz`, and also `Bearer realm=` - a parameter needs a
      non-empty value, so that reads as token68 `realm=`).
    * Quoted strings honour `\\` escapes (quoted-pair); commas, `=` and
      spaces inside quotes are data. A bare control character (CR, LF, NUL,
      ...) anywhere is an error, so a header cannot smuggle a line break.
    * Scheme and parameter names are case-insensitive: both are stored
      lowercased (ASCII). Values are kept exactly as sent and must be valid
      UTF-8.

  Malformed input never raises: it returns `{:error, %OAuth.Error{reason:
  :invalid_challenge, data: detail}}`, and the whole input is rejected (no
  partial result), so the caller falls back to well-known discovery.

  ## Duplicates

  RFC 9110 §11.2 says each parameter name "MUST only occur once per
  challenge" and RFC 6750 §3 says Bearer attributes "MUST NOT appear more
  than once". A repeated name (compared case-insensitively) is rejected with
  detail `:duplicate_param` rather than resolved first- or last-wins: two
  parties reading the same header must never disagree about, say,
  `resource_metadata`.

  ## Limits

    * 8192 bytes across all values (detail `:too_large`);
    * 16 challenges in total (`:too_many_challenges`);
    * 32 parameters per challenge (`:too_many_params`).

  Other details: `:invalid_input` (not a string or list of strings),
  `:malformed`, `:unterminated_quote`, `:invalid_encoding`.
  """

  alias ConduitMcp.Client.OAuth.{Error, Scopes}

  @max_bytes 8192
  @max_challenges 16
  @max_params 32

  @enforce_keys [:scheme]
  defstruct scheme: nil, params: %{}, token68: nil

  @typedoc """
  One challenge. `scheme` and the `params` keys are lowercase; `token68` is
  set (and `params` empty) for the token68 form.
  """
  @type t :: %__MODULE__{
          scheme: String.t(),
          params: %{optional(String.t()) => String.t()},
          token68: String.t() | nil
        }

  @type detail ::
          :invalid_input
          | :too_large
          | :too_many_challenges
          | :too_many_params
          | :duplicate_param
          | :unterminated_quote
          | :invalid_encoding
          | :malformed

  defguardp tchar?(c)
            when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or
                   c in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]

  defguardp token68_char?(c)
            when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?., ?_, ?~, ?+, ?/]

  defguardp ows?(c) when c in [?\s, ?\t]

  # qdtext and the escaped character of a quoted-pair, minus `"` and `\`
  # (RFC 9110 §5.6.4); obs-text (0x80-0xFF) is admitted, UTF-8 is checked after.
  defguardp qdtext?(c) when c in [?\t, ?\s, ?!] or c in 0x23..0x5B or c in 0x5D..0x7E or c >= 0x80

  defguardp quoted_pair?(c) when c in [?\t, ?\s] or c in 0x21..0x7E or c >= 0x80

  @doc """
  Parses one `WWW-Authenticate` value, or a list of values (one per header).

      iex> ConduitMcp.Client.OAuth.Challenge.parse([~s(Basic realm="a, b"), "Bearer"])
      {:ok,
       [
         %ConduitMcp.Client.OAuth.Challenge{scheme: "basic", params: %{"realm" => "a, b"}},
         %ConduitMcp.Client.OAuth.Challenge{scheme: "bearer", params: %{}}
       ]}
  """
  @spec parse(String.t() | [String.t()]) :: {:ok, [t()]} | {:error, Error.t()}
  def parse(value) when is_binary(value), do: parse([value])

  def parse(values) when is_list(values) do
    cond do
      not Enum.all?(values, &is_binary/1) -> invalid(:invalid_input)
      Enum.reduce(values, 0, &(byte_size(&1) + &2)) > @max_bytes -> invalid(:too_large)
      true -> parse_values(values, [])
    end
  end

  def parse(_value), do: invalid(:invalid_input)

  @doc """
  The first challenge with the `Bearer` scheme, or `nil`. Takes the list
  from `parse/1`; RFC 6750 defines a single Bearer challenge, so any later
  ones are ignored.
  """
  @spec bearer([t()]) :: t() | nil
  def bearer(challenges) when is_list(challenges),
    do: Enum.find(challenges, &match?(%__MODULE__{scheme: "bearer"}, &1))

  @doc "The value of parameter `name` (matched case-insensitively), or `nil`."
  @spec param(t(), String.t()) :: String.t() | nil
  def param(%__MODULE__{params: params}, name) when is_binary(name),
    do: Map.get(params, String.downcase(name, :ascii))

  @doc """
  The `resource_metadata` URL (RFC 9728 §5.1), or `nil`. It is server data:
  validate it and pass it through `ConduitMcp.Client.URLPolicy` before
  fetching.
  """
  @spec resource_metadata(t()) :: String.t() | nil
  def resource_metadata(challenge), do: param(challenge, "resource_metadata")

  @doc "The challenged scopes (RFC 6750 §3 `scope`, space-delimited), `[]` when absent."
  @spec scopes(t()) :: [String.t()]
  def scopes(challenge), do: challenge |> param("scope") |> Scopes.parse()

  @doc "The RFC 6750 §3.1 `error` code (for example `\"insufficient_scope\"`), or `nil`."
  @spec error(t()) :: String.t() | nil
  def error(challenge), do: param(challenge, "error")

  @doc "The `error_description`, or `nil`. Server text: never render it as trusted."
  @spec error_description(t()) :: String.t() | nil
  def error_description(challenge), do: param(challenge, "error_description")

  @doc "Whether the challenge is a step-up request (`error=\"insufficient_scope\"`)."
  @spec insufficient_scope?(t()) :: boolean()
  def insufficient_scope?(challenge), do: error(challenge) == "insufficient_scope"

  ## Parser

  # `acc` holds the challenges parsed so far, newest first, across values.
  defp parse_values([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_values([value | rest], acc) do
    case challenges(skip_separators(value), acc) do
      {:ok, acc} -> parse_values(rest, acc)
      {:error, detail} -> invalid(detail)
    end
  end

  defp challenges(<<>>, acc), do: {:ok, acc}

  defp challenges(_input, acc) when length(acc) >= @max_challenges,
    do: {:error, :too_many_challenges}

  defp challenges(input, acc) do
    with {:ok, scheme, rest} <- token(input),
         {:ok, challenge, rest} <- challenge_body(String.downcase(scheme, :ascii), rest) do
      case rest do
        <<>> -> {:ok, [challenge | acc]}
        <<?,, _::binary>> -> challenges(skip_separators(rest), [challenge | acc])
        _ -> {:error, :malformed}
      end
    end
  end

  # Returns the rest positioned at the end or at the comma after the challenge.
  defp challenge_body(scheme, <<c, _::binary>> = input) when ows?(c) do
    case skip_ows(input) do
      <<>> ->
        {:ok, %__MODULE__{scheme: scheme}, <<>>}

      <<?,, _::binary>> = rest ->
        {:ok, %__MODULE__{scheme: scheme}, rest}

      rest ->
        case token68(rest) do
          {:ok, value, rest} -> {:ok, %__MODULE__{scheme: scheme, token68: value}, rest}
          :error -> params(scheme, rest, %{})
        end
    end
  end

  defp challenge_body(scheme, <<>>), do: {:ok, %__MODULE__{scheme: scheme}, <<>>}

  defp challenge_body(scheme, <<?,, _::binary>> = rest),
    do: {:ok, %__MODULE__{scheme: scheme}, rest}

  defp challenge_body(_scheme, _rest), do: {:error, :malformed}

  defp params(scheme, input, acc) do
    with {:ok, name, rest} <- token(input),
         <<?=, rest::binary>> <- skip_ows(rest),
         {:ok, value, rest} <- param_value(skip_ows(rest)),
         {:ok, acc} <- put_param(acc, String.downcase(name, :ascii), value) do
      case skip_ows(rest) do
        <<>> ->
          {:ok, %__MODULE__{scheme: scheme, params: acc}, <<>>}

        <<?,, _::binary>> = rest ->
          next = skip_separators(rest)

          if param_ahead?(next),
            do: params(scheme, next, acc),
            else: {:ok, %__MODULE__{scheme: scheme, params: acc}, rest}

        _ ->
          {:error, :malformed}
      end
    else
      {:error, _detail} = error -> error
      _no_equals -> {:error, :malformed}
    end
  end

  defp put_param(acc, name, _value) when is_map_key(acc, name), do: {:error, :duplicate_param}

  defp put_param(acc, _name, _value) when map_size(acc) >= @max_params,
    do: {:error, :too_many_params}

  defp put_param(acc, name, value) do
    if String.valid?(value),
      do: {:ok, Map.put(acc, name, value)},
      else: {:error, :invalid_encoding}
  end

  defp param_ahead?(input) do
    case token(input) do
      {:ok, _name, rest} -> match?(<<?=, _::binary>>, skip_ows(rest))
      {:error, _detail} -> false
    end
  end

  defp param_value(<<?", rest::binary>>), do: quoted(rest, [])
  defp param_value(input), do: token(input)

  defp quoted(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  defp quoted(<<?\\, c, rest::binary>>, acc) when quoted_pair?(c), do: quoted(rest, [c | acc])
  defp quoted(<<c, rest::binary>>, acc) when qdtext?(c), do: quoted(rest, [c | acc])
  defp quoted(<<>>, _acc), do: {:error, :unterminated_quote}
  defp quoted(<<?\\>>, _acc), do: {:error, :unterminated_quote}
  defp quoted(_input, _acc), do: {:error, :malformed}

  defp token(input) do
    case take_while(input, &tchar_byte?/1) do
      {<<>>, _rest} -> {:error, :malformed}
      {token, rest} -> {:ok, token, rest}
    end
  end

  # token68 must be followed (after OWS) by the end or a comma.
  defp token68(input) do
    {chars, rest} = take_while(input, &token68_byte?/1)
    {padding, rest} = take_while(rest, &(&1 == ?=))
    rest = skip_ows(rest)

    if chars != <<>> and (rest == <<>> or binary_part(rest, 0, 1) == ","),
      do: {:ok, chars <> padding, rest},
      else: :error
  end

  defp take_while(input, fun), do: take_while(input, fun, 0)

  defp take_while(input, fun, n) do
    case input do
      <<_::binary-size(^n), c, _::binary>> ->
        if fun.(c), do: take_while(input, fun, n + 1), else: split(input, n)

      _ ->
        split(input, n)
    end
  end

  defp split(input, n),
    do: {binary_part(input, 0, n), binary_part(input, n, byte_size(input) - n)}

  defp tchar_byte?(c) when tchar?(c), do: true
  defp tchar_byte?(_c), do: false

  defp token68_byte?(c) when token68_char?(c), do: true
  defp token68_byte?(_c), do: false

  defp skip_ows(<<c, rest::binary>>) when ows?(c), do: skip_ows(rest)
  defp skip_ows(input), do: input

  defp skip_separators(<<c, rest::binary>>) when ows?(c) or c == ?,, do: skip_separators(rest)
  defp skip_separators(input), do: input

  defp invalid(detail), do: Error.error(:invalid_challenge, detail)
end
