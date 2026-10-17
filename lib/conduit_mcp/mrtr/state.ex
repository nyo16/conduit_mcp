defmodule ConduitMcp.MRTR.State do
  @moduledoc """
  Seals and opens the MRTR `requestState` token.

  The spec requires servers to treat `requestState` as attacker-controlled.
  `seal/3` encrypts the handler's state term with AES-256-GCM (a fresh 96-bit
  IV per seal) and binds it to the request that produced it; `open/3`
  returns the term only when every binding still holds.

  ## Configuration

  MRTR requires a keyring:

      config :conduit_mcp, mrtr_keys: [{"2026-10", key32}, {"2026-07", old_key32}]

  Each entry is `{kid, key}`: `kid` is a non-empty binary without `"."`, `key`
  exactly 32 random bytes (e.g. `:crypto.strong_rand_bytes(32)`, loaded from a
  secret at runtime). `seal/3` always uses the **first** key; `open/3` selects
  the key named by the token's `kid`. To rotate, put the new key first and
  keep the old one second until in-flight tokens (at most 5 minutes old) have
  expired, then remove it. Rotate well before 2³² seals per key, the GCM
  random-IV bound. Keys are read at runtime; when configured they are
  validated at application boot (`validate_keys!/1`). Without `:mrtr_keys`,
  `seal/3` raises and `open/3` returns `:error`.

  ## Bindings

  The binding passed to both calls is
  `%{version: v, method: m, params: p, principal: id}`:

    * **AAD** — the protocol `version`, `method`, and `kid`.
    * **Payload** — the `principal` id (use `ConduitMcp.Principal.id/1`, the
      claim-prefixed id, or `nil` when unauthenticated), an expiry (5 minutes,
      60 seconds when `principal` is nil), a SHA-256 digest of `method` and
      the *salient* params, and the state term.

  Salient params are the request `params` minus `"_meta"`,
  `"inputResponses"`, and `"requestState"` — the fields that legitimately
  change between rounds — canonicalized as JSON with sorted object keys. A
  token presented on a different tool, arguments, URI, or prompt is rejected.

  Replay inside the expiry window by the same principal on the same request
  is bounded, not prevented; single-use redemption needs server-side storage.

  ## Token format

  `kid <> "." <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)`.
  Tokens longer than 64 KiB are rejected before any decoding. The payload is
  JSON; `:erlang.binary_to_term/1` is never used.

  ## State terms

  The state must be JSON-encodable: `nil`, booleans, numbers, UTF-8 strings,
  atoms (encoded as strings), lists, and maps with string or atom keys.
  Tuples, pids, references, funs, ports, and non-UTF-8 binaries raise
  `ArgumentError` at seal time. `open/3` returns the decoded JSON, so atom
  keys and values come back as strings.
  """

  @separator "."
  @max_token_bytes 64 * 1024
  @iv_bytes 12
  @tag_bytes 16
  @ttl_ms :timer.minutes(5)
  @anonymous_ttl_ms :timer.seconds(60)
  @unsalient ["_meta", "inputResponses", "requestState"]

  @typedoc "What a token is bound to; `principal` is a derived principal id or nil."
  @type binding :: %{
          required(:version) => String.t(),
          required(:method) => String.t(),
          required(:params) => map() | nil,
          required(:principal) => String.t() | nil
        }

  @doc """
  Seals `state` into a `requestState` token bound to `binding`.

  Options: `:now` — current time in milliseconds since the epoch (defaults to
  `System.system_time(:millisecond)`).

  Raises `ArgumentError` when `state` is not JSON-encodable or `:mrtr_keys` is
  not configured.
  """
  @spec seal(term(), binding(), keyword()) :: String.t()
  def seal(state, binding, opts \\ []) do
    validate_json!(state)
    {kid, key} = signing_key!()
    now = Keyword.get_lazy(opts, :now, &now_ms/0)
    ttl = if is_nil(binding.principal), do: @anonymous_ttl_ms, else: @ttl_ms

    plaintext =
      JSON.encode!(%{
        "p" => binding.principal,
        "e" => now + ttl,
        "d" => Base.encode16(digest(binding), case: :lower),
        "s" => state
      })

    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad(kid, binding), true)

    kid <> @separator <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)
  end

  @doc """
  Opens a token produced by `seal/3`, returning `{:ok, state}`.

  Returns `:error` — the same value whatever the cause — for an oversize,
  truncated, malformed or tampered token, an unknown `kid`, a different
  principal, version, method or salient params, or an expired token.

  Options: `:now`, as in `seal/3`.
  """
  @spec open(term(), binding(), keyword()) :: {:ok, term()} | :error
  def open(token, binding, opts \\ [])

  def open(token, binding, opts)
      when is_binary(token) and byte_size(token) <= @max_token_bytes do
    now = Keyword.get_lazy(opts, :now, &now_ms/0)

    with [kid, encoded] <- :binary.split(token, @separator),
         {:ok, key} <- fetch_key(kid),
         {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(kid, binding),
             tag,
             false
           ),
         {:ok, %{"p" => principal, "e" => expiry, "d" => digest, "s" => state}} <-
           JSON.decode(plaintext),
         true <- principal == binding.principal,
         true <- is_integer(expiry) and now < expiry,
         true <- :crypto.hash_equals(digest, Base.encode16(digest(binding), case: :lower)) do
      {:ok, state}
    else
      _ -> :error
    end
  end

  def open(_token, _binding, _opts), do: :error

  @doc """
  Validates a `:mrtr_keys` keyring, raising `ArgumentError` naming the config
  key (never the key bytes) when it is malformed.

  `ConduitMcp.Application` calls this at boot when `:mrtr_keys` is set.
  """
  @spec validate_keys!(term()) :: :ok
  def validate_keys!([_ | _] = keys) do
    keys
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} -> validate_entry!(entry, index) end)

    kids = Enum.map(keys, &elem(&1, 0))

    if length(Enum.uniq(kids)) != length(kids) do
      raise ArgumentError, "config :conduit_mcp, :mrtr_keys has duplicate kids"
    end

    :ok
  end

  def validate_keys!(_other) do
    raise ArgumentError,
          "config :conduit_mcp, :mrtr_keys must be a non-empty list of {kid, key} tuples"
  end

  defp validate_entry!({kid, key}, index) when is_binary(kid) and is_binary(key) do
    cond do
      kid == "" or String.contains?(kid, @separator) ->
        raise ArgumentError,
              "config :conduit_mcp, :mrtr_keys entry #{index}: kid must be a non-empty " <>
                "binary without #{inspect(@separator)}"

      byte_size(key) != 32 ->
        raise ArgumentError,
              "config :conduit_mcp, :mrtr_keys entry #{index}: key must be exactly 32 bytes, " <>
                "got #{byte_size(key)}"

      true ->
        :ok
    end
  end

  defp validate_entry!(_entry, index) do
    raise ArgumentError,
          "config :conduit_mcp, :mrtr_keys entry #{index} must be a {kid, key} tuple of binaries"
  end

  defp signing_key! do
    case Application.get_env(:conduit_mcp, :mrtr_keys) do
      [{kid, key} | _] when is_binary(kid) and is_binary(key) and byte_size(key) == 32 ->
        {kid, key}

      _ ->
        raise ArgumentError,
              "MRTR requires `config :conduit_mcp, :mrtr_keys, [{kid, key32}]` " <>
                "(see ConduitMcp.MRTR.State)"
    end
  end

  defp fetch_key(kid) do
    case List.keyfind(Application.get_env(:conduit_mcp, :mrtr_keys) || [], kid, 0) do
      {^kid, key} when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _ -> :error
    end
  end

  # A JSON array is an unambiguous encoding of the three fields.
  defp aad(kid, binding), do: JSON.encode!([binding.version, binding.method, kid])

  defp digest(binding) do
    salient = Map.drop(binding.params || %{}, @unsalient)
    :crypto.hash(:sha256, canonical([binding.method, salient]))
  end

  defp canonical(map) when is_map(map) do
    fields =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, canonical(v)] end)
      |> Enum.intersperse(?,)

    [?{, fields, ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, list |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]

  defp canonical(value), do: JSON.encode!(value)

  defp validate_json!(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
       do: :ok

  defp validate_json!(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: reject!(value)
  end

  defp validate_json!(list) when is_list(list) do
    if proper_list?(list), do: Enum.each(list, &validate_json!/1), else: reject!(list)
  end

  defp validate_json!(%_{} = struct), do: reject!(struct)

  defp validate_json!(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      unless is_atom(key) or (is_binary(key) and String.valid?(key)), do: reject!(key)
      validate_json!(value)
    end)
  end

  defp validate_json!(other), do: reject!(other)

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp reject!(value) do
    raise ArgumentError,
          "MRTR state must be JSON-encodable (nil, booleans, numbers, UTF-8 strings, " <>
            "atoms, lists, maps with string or atom keys); got a #{kind(value)}"
  end

  defp kind(value) when is_tuple(value), do: "tuple"
  defp kind(value) when is_pid(value), do: "pid"
  defp kind(value) when is_reference(value), do: "reference"
  defp kind(value) when is_function(value), do: "function"
  defp kind(value) when is_port(value), do: "port"
  defp kind(%struct{}), do: "struct #{inspect(struct)}"
  defp kind(value) when is_binary(value), do: "non-UTF-8 binary"
  defp kind(value) when is_list(value), do: "improper list"
  defp kind(_value), do: "non-JSON term"

  defp now_ms, do: System.system_time(:millisecond)
end
