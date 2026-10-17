defmodule ConduitMcp.Client.Backoff do
  @moduledoc """
  Reconnect delays for `ConduitMcp.Client`.

  `full_jitter/2` is the default `:backoff` of `ConduitMcp.Client.Config`:
  a uniformly random delay between 1 ms and `min(cap, base * 2 ** attempt)`
  ("full jitter"), so many clients that lost the same server do not
  reconnect in lockstep. `attempt` is 1 for the first reconnect.
  """

  @base 500
  @cap 30_000
  # 2 ** 16 * 500 already exceeds any sane cap; bounding the exponent keeps
  # a large attempt count from building a bignum.
  @max_exponent 16

  @doc """
  A full-jitter exponential delay in milliseconds for reconnect `attempt`.

  ## Options

    * `:base` - the first step, in milliseconds (default `500`).
    * `:cap` - the largest delay, in milliseconds (default `30_000`).

  ## Example

      iex> delay = ConduitMcp.Client.Backoff.full_jitter(1)
      iex> delay in 1..1_000
      true
  """
  @spec full_jitter(non_neg_integer(), keyword()) :: pos_integer()
  def full_jitter(attempt, opts \\ []) when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :base, @base)
    cap = Keyword.get(opts, :cap, @cap)
    :rand.uniform(max(1, min(cap, base * 2 ** min(attempt, @max_exponent))))
  end
end
