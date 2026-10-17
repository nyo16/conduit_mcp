defmodule ConduitMcp.Client.RateLimit do
  @moduledoc false

  # A lock-free per-server limiter for server-to-client input requests
  # (GCRA over one `:atomics` cell holding the theoretical arrival time).
  # The connection creates it and publishes it in the client's registry
  # value, so a legacy handler task and a modern MRTR caller draw from the
  # same budget without messaging anyone.

  @enforce_keys [:ref, :interval, :tolerance]
  defstruct [:ref, :interval, :tolerance]

  @type t :: %__MODULE__{
          ref: :atomics.atomics_ref(),
          interval: pos_integer(),
          tolerance: integer()
        }

  @doc "`per_second` requests on average, up to `burst` at once."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(per_second, burst)
      when is_integer(per_second) and per_second > 0 and is_integer(burst) and burst > 0 do
    interval = div(1_000_000, per_second)
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, now())
    %__MODULE__{ref: ref, interval: max(interval, 1), tolerance: max(interval, 1) * (burst - 1)}
  end

  @doc "Takes one request from the budget: `:ok`, or `:rate_limited`."
  @spec check(t()) :: :ok | :rate_limited
  def check(%__MODULE__{} = limiter), do: check(limiter, now())

  defp check(%{ref: ref, interval: interval, tolerance: tolerance} = limiter, now) do
    tat = :atomics.get(ref, 1)
    base = max(tat, now)

    cond do
      base - now > tolerance -> :rate_limited
      :atomics.compare_exchange(ref, 1, tat, base + interval) == :ok -> :ok
      true -> check(limiter, now)
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
end
