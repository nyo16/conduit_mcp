defmodule ConduitMcp.Client.Secret do
  @moduledoc """
  An opaque wrapper for values that must never be printed or encoded by
  accident: bearer tokens, refresh tokens, MRTR `requestState`, legacy
  session ids, and environment values.

      iex> secret = ConduitMcp.Client.Secret.new("s3cr3t")
      iex> inspect(secret)
      "#Secret<redacted>"
      iex> ConduitMcp.Client.Secret.expose(secret)
      "s3cr3t"

  ## What it guards against

    * **`inspect/2`** (and so `IO.inspect`, ExUnit diffs, `Logger` messages
      built with `inspect`, Elixir crash-report translation of exceptions and
      arguments) prints `#Secret<redacted>`.
    * **String interpolation and `to_string/1`** raise `Protocol.UndefinedError`:
      there is deliberately no `String.Chars` implementation, and the error
      message itself inspects the value, so it stays redacted.
    * **`Logger` metadata** is dropped by `Logger.Formatter`, which renders only
      metadata values that implement `String.Chars`.
    * **`JSON.encode!/1`** raises `ArgumentError` without the value. Raising
      rather than writing a placeholder such as `"[redacted]"` is deliberate:
      encoding a secret is always a programming error (wire code calls
      `expose/1` exactly where the value belongs), a placeholder would send a
      bogus credential or `requestState` to the server and fail later and far
      away, and the raise happens while the iodata is being built, so no byte
      reaches the wire. The exception message names the module, never the
      value, so a crash report for the raise does not leak either.

  ## What it does not guard against

  Raw Erlang term printing (`:io_lib.format("~p", ...)`, `:sys.get_state/1`,
  `:erlang.term_to_binary/1`) sees the struct's fields. Every client process
  that holds a `Secret` in its state therefore implements `format_status/1`
  to redact it.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: term()}

  @doc """
  Wraps `value`. Wrapping an existing `Secret` returns it unchanged.
  """
  @spec new(term()) :: t()
  def new(%__MODULE__{} = secret), do: secret
  def new(value), do: %__MODULE__{value: value}

  @doc """
  Returns the wrapped value. Call it only where the value is put on the wire
  or handed to code that needs the plain value.
  """
  @spec expose(t()) :: term()
  def expose(%__MODULE__{value: value}), do: value

  @doc "Whether `term` is a `Secret`."
  @spec secret?(term()) :: boolean()
  def secret?(%__MODULE__{}), do: true
  def secret?(_term), do: false

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Secret<redacted>"
  end

  defimpl JSON.Encoder do
    def encode(_secret, _encoder) do
      raise ArgumentError,
            "refusing to JSON-encode a ConduitMcp.Client.Secret; " <>
              "call ConduitMcp.Client.Secret.expose/1 where the value belongs on the wire"
    end
  end
end
