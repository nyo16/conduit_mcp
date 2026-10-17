defmodule ConduitMcp.Client.URLPolicy do
  @moduledoc """
  Decides whether the client may connect to a URL, before any connection is
  made. It guards against server-supplied URLs (OAuth metadata, redirects,
  `resource_metadata`) pointing the client at internal networks (SSRF).

      iex> ConduitMcp.Client.URLPolicy.check("https://127.1/", :public_only)
      {:error, {:blocked_address, {127, 0, 0, 1}}}

  ## Policies

    * `:public_only` - `https` only; the host is resolved (A and AAAA) and the
      URL is refused if **any** address is blocked (see below), unless that
      address falls inside an `:allow_private` CIDR. An IP-literal host is
      checked directly.
    * `:any` - `http` or `https`, no address checks and no DNS lookup.

  On success the result carries the resolved `addresses`, so the caller can
  connect to exactly those (pinning) instead of resolving again and racing a
  DNS rebind; `host` stays the hostname for TLS SNI and certificate checks.

  ## Host parsing

  Hosts are parsed, never pattern-matched as strings. A host whose last label
  is numeric is parsed with the WHATWG URL IPv4 rules, so every notation a
  browser or resolver accepts is normalized first: `127.1`, `0x7f.1`,
  `0177.0.0.1`, `017700000001`, `2130706433` and `127.0.0.1.` are all
  `{127, 0, 0, 1}`, and an invalid numeric host (`1.2.3.4.5`, `09.1`) is
  refused. Bracketed IPv6 literals are parsed strictly. A URL with user info,
  a percent-encoded or non-ASCII host, an IPv6 zone id, a backslash, or
  whitespace or control characters is refused outright.

  ## Blocked addresses

  IPv4: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`,
  `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.168.0.0/16`,
  `198.18.0.0/15`, `224.0.0.0/4`, `240.0.0.0/4`.

  IPv6: `::/96` (which holds `::`, `::1` and the deprecated IPv4-compatible
  form), `100::/64`, `64:ff9b:1::/48`, `fc00::/7`, `fe80::/10`, `fec0::/10`,
  `ff00::/8`. IPv6 forms that embed an IPv4 address are unwrapped and the
  embedded address is checked against the IPv4 list: IPv4-mapped
  `::ffff:0:0/96`, IPv4-translated `::ffff:0:0:0/96`, NAT64 `64:ff9b::/96`
  and 6to4 `2002::/16`. So `[::ffff:127.0.0.1]` and `[64:ff9b::a00:1]` are
  blocked, while a NAT64 address embedding a public IPv4 address (as DNS64
  networks synthesize) is not.
  """

  import Bitwise

  @typedoc "A CIDR block: a base address and a prefix length."
  @type cidr :: {:inet.ip_address(), non_neg_integer()}

  @type policy :: :public_only | :any

  @type target :: %{
          scheme: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          addresses: [:inet.ip_address()]
        }

  @type reason ::
          :invalid_url
          | {:scheme_not_allowed, String.t() | nil}
          | :userinfo_not_allowed
          | :invalid_host
          | {:blocked_address, :inet.ip_address()}
          | {:resolve_failed, term()}

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @blocked_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @default_resolve_timeout 5_000

  @doc """
  Checks `url` against `policy`.

  ## Options

    * `:allow_private` - CIDRs (strings such as `"10.1.0.0/16"`, or
      `t:cidr/0` tuples) whose addresses `:public_only` admits even though
      they are blocked. Raises `ArgumentError` on an invalid entry.
    * `:resolver` - `t:resolver/0` used for hostnames (default: the system
      resolver, A and AAAA).
    * `:resolve_timeout` - milliseconds per lookup family for the default
      resolver (default 5000).
  """
  @spec check(String.t(), policy(), keyword()) :: {:ok, target()} | {:error, reason()}
  def check(url, policy, opts \\ []) when policy in [:public_only, :any] and is_binary(url) do
    allow = opts |> Keyword.get(:allow_private, []) |> Enum.map(&parse_cidr!/1)

    with :ok <- check_characters(url),
         {:ok, uri} <- parse_uri(url),
         {:ok, scheme} <- check_scheme(uri.scheme, policy),
         :ok <- check_userinfo(uri.userinfo),
         {:ok, host} <- parse_host(uri.host),
         {:ok, addresses} <- addresses(host, policy, opts),
         :ok <- check_addresses(addresses, policy, allow) do
      {:ok, %{scheme: scheme, host: host_string(host), port: uri.port, addresses: addresses}}
    end
  end

  @doc """
  Whether `address` is in a blocked range, after unwrapping IPv6 forms that
  embed an IPv4 address (see the moduledoc).

      iex> ConduitMcp.Client.URLPolicy.blocked?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      true
      iex> ConduitMcp.Client.URLPolicy.blocked?({93, 184, 216, 34})
      false
  """
  @spec blocked?(:inet.ip_address()) :: boolean()
  def blocked?({_, _, _, _} = ip), do: Enum.any?(@blocked_v4, &in_cidr?(ip, &1))

  def blocked?({_, _, _, _, _, _, _, _} = ip) do
    case embedded_v4(ip) do
      {:ok, v4} -> blocked?(v4)
      :none -> Enum.any?(@blocked_v6, &in_cidr?(ip, &1))
    end
  end

  @doc """
  Parses a CIDR string (`"10.0.0.0/8"`, `"fd00::/8"`; a bare address is a
  single host) or validates a `t:cidr/0` tuple.

      iex> ConduitMcp.Client.URLPolicy.parse_cidr("10.0.0.0/8")
      {:ok, {{10, 0, 0, 0}, 8}}
  """
  @spec parse_cidr(String.t() | cidr()) :: {:ok, cidr()} | :error
  def parse_cidr({ip, prefix} = cidr) when is_tuple(ip) and is_integer(prefix) do
    if :inet.is_ip_address(ip) and prefix in 0..bits(ip), do: {:ok, cidr}, else: :error
  end

  def parse_cidr(cidr) when is_binary(cidr) do
    {address, prefix} =
      case String.split(cidr, "/") do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
        _ -> {nil, nil}
      end

    with true <- is_binary(address),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {:ok, prefix} <- parse_prefix(prefix, bits(ip)) do
      {:ok, {ip, prefix}}
    else
      _ -> :error
    end
  end

  def parse_cidr(_cidr), do: :error

  defp parse_prefix(nil, max), do: {:ok, max}

  defp parse_prefix(text, max) do
    case Integer.parse(text) do
      {prefix, ""} when prefix in 0..max//1 -> {:ok, prefix}
      _ -> :error
    end
  end

  defp parse_cidr!(cidr) do
    case parse_cidr(cidr) do
      {:ok, parsed} -> parsed
      :error -> raise ArgumentError, "invalid :allow_private CIDR: #{inspect(cidr)}"
    end
  end

  # -- URL -------------------------------------------------------------------

  defp check_characters(url) do
    if url == "" or has_forbidden_byte?(url), do: {:error, :invalid_url}, else: :ok
  end

  defp has_forbidden_byte?(<<>>), do: false
  defp has_forbidden_byte?(<<c, _::binary>>) when c <= 0x20 or c == 0x7F or c == ?\\, do: true
  defp has_forbidden_byte?(<<_, rest::binary>>), do: has_forbidden_byte?(rest)

  defp parse_uri(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp check_scheme(scheme, policy) do
    case {scheme && String.downcase(scheme), policy} do
      {"https", _policy} -> {:ok, "https"}
      {"http", :any} -> {:ok, "http"}
      _other -> {:error, {:scheme_not_allowed, scheme}}
    end
  end

  defp check_userinfo(nil), do: :ok
  defp check_userinfo(_userinfo), do: {:error, :userinfo_not_allowed}

  # -- Host ------------------------------------------------------------------

  defp parse_host(host) when host in [nil, ""], do: {:error, :invalid_host}

  defp parse_host(host) do
    cond do
      String.contains?(host, ":") -> parse_ipv6(host)
      not hostname_bytes?(host) -> {:error, :invalid_host}
      ends_in_number?(host) -> parse_ipv4(host)
      true -> parse_name(host)
    end
  end

  defp parse_ipv6(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, {:ip, ip}}
      {:error, _} -> {:error, :invalid_host}
    end
  end

  defp hostname_bytes?(host) do
    byte_size(host) <= 253 and
      host |> :binary.bin_to_list() |> Enum.all?(&hostname_byte?/1)
  end

  defp hostname_byte?(c),
    do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?.]

  defp parse_name(host) do
    labels = host |> String.downcase() |> labels()

    if labels != [] and Enum.all?(labels, &(&1 != "" and byte_size(&1) <= 63)),
      do: {:ok, {:name, Enum.join(labels, ".")}},
      else: {:error, :invalid_host}
  end

  # A single trailing dot (fully-qualified form) is not a label.
  defp labels(host) do
    case String.split(host, ".") do
      [_ | [_ | _]] = parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
      parts -> parts
    end
  end

  # WHATWG URL "ends in a number checker".
  defp ends_in_number?(host) do
    last = host |> labels() |> List.last()
    last != "" and (all_in?(last, ?0..?9) or ipv4_number(last) != :error)
  end

  # WHATWG URL "IPv4 parser": 1-4 parts, each decimal, octal (leading 0) or
  # hex (0x); the last part fills the remaining bytes.
  defp parse_ipv4(host) do
    parts = labels(host)

    with true <- length(parts) <= 4,
         numbers when is_list(numbers) <- parse_ipv4_numbers(parts),
         {init, [last]} = Enum.split(numbers, -1),
         true <- Enum.all?(init, &(&1 <= 255)),
         true <- last < 256 ** (5 - length(numbers)) do
      value =
        init
        |> Enum.with_index()
        |> Enum.reduce(last, fn {n, i}, acc -> acc + n * 256 ** (3 - i) end)

      {:ok,
       {:ip, {value >>> 24 &&& 0xFF, value >>> 16 &&& 0xFF, value >>> 8 &&& 0xFF, value &&& 0xFF}}}
    else
      _ -> {:error, :invalid_host}
    end
  end

  defp parse_ipv4_numbers(parts) do
    Enum.reduce_while(parts, [], fn part, acc ->
      case ipv4_number(part) do
        :error -> {:halt, :error}
        n -> {:cont, acc ++ [n]}
      end
    end)
  end

  defp ipv4_number(""), do: :error
  defp ipv4_number(<<?0, x, rest::binary>>) when x in [?x, ?X], do: digits(rest, 16)
  defp ipv4_number(<<?0, rest::binary>>) when rest != "", do: digits(rest, 8)
  defp ipv4_number(text), do: digits(text, 10)

  defp digits("", _radix), do: 0

  defp digits(text, 16) do
    if all_in?(text, [?0..?9, ?a..?f, ?A..?F]), do: String.to_integer(text, 16), else: :error
  end

  defp digits(text, 8),
    do: if(all_in?(text, ?0..?7), do: String.to_integer(text, 8), else: :error)

  defp digits(text, 10), do: if(all_in?(text, ?0..?9), do: String.to_integer(text), else: :error)

  defp all_in?(text, %Range{} = range), do: all_in?(text, [range])

  defp all_in?(text, ranges) do
    text |> :binary.bin_to_list() |> Enum.all?(fn c -> Enum.any?(ranges, &(c in &1)) end)
  end

  defp host_string({:name, name}), do: name
  defp host_string({:ip, ip}), do: ip |> :inet.ntoa() |> List.to_string()

  # -- Addresses -------------------------------------------------------------

  defp addresses({:ip, ip}, _policy, _opts), do: {:ok, [ip]}
  defp addresses({:name, _name}, :any, _opts), do: {:ok, []}

  defp addresses({:name, name}, :public_only, opts) do
    resolver = Keyword.get(opts, :resolver, &default_resolve(&1, opts))

    case resolver.(name) do
      {:ok, [_ | _] = ips} ->
        if Enum.all?(ips, &:inet.is_ip_address/1),
          do: {:ok, Enum.uniq(ips)},
          else: {:error, {:resolve_failed, :invalid_address}}

      {:ok, []} ->
        {:error, {:resolve_failed, :nxdomain}}

      {:error, reason} ->
        {:error, {:resolve_failed, reason}}
    end
  end

  defp default_resolve(name, opts) do
    timeout = Keyword.get(opts, :resolve_timeout, @default_resolve_timeout)
    host = String.to_charlist(name)
    results = for family <- [:inet, :inet6], do: :inet.getaddrs(host, family, timeout)

    case for({:ok, ips} <- results, ip <- ips, do: ip) do
      [] -> Enum.find(results, {:error, :nxdomain}, &match?({:error, _}, &1))
      ips -> {:ok, ips}
    end
  end

  defp check_addresses(_addresses, :any, _allow), do: :ok

  defp check_addresses(addresses, :public_only, allow) do
    case Enum.find(addresses, &(blocked?(&1) and not allowed?(&1, allow))) do
      nil -> :ok
      ip -> {:error, {:blocked_address, ip}}
    end
  end

  defp allowed?(ip, allow) do
    candidates =
      case ip do
        {_, _, _, _, _, _, _, _} ->
          case embedded_v4(ip) do
            {:ok, v4} -> [ip, v4]
            :none -> [ip]
          end

        _v4 ->
          [ip]
      end

    Enum.any?(allow, fn cidr -> Enum.any?(candidates, &in_cidr?(&1, cidr)) end)
  end

  # IPv4-mapped ::ffff:a.b.c.d, IPv4-translated ::ffff:0:a.b.c.d,
  # NAT64 64:ff9b::a.b.c.d, and 6to4 2002:AABB:CCDD::/48.
  defp embedded_v4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {:ok, v4(hi, lo)}
  defp embedded_v4({0, 0, 0, 0, 0xFFFF, 0, hi, lo}), do: {:ok, v4(hi, lo)}
  defp embedded_v4({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: {:ok, v4(hi, lo)}
  defp embedded_v4({0x2002, hi, lo, _, _, _, _, _}), do: {:ok, v4(hi, lo)}
  defp embedded_v4(_ip), do: :none

  defp v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp in_cidr?(ip, {base, prefix}) when tuple_size(ip) == tuple_size(base) do
    shift = bits(ip) - prefix
    to_integer(ip) >>> shift == to_integer(base) >>> shift
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(ip) when tuple_size(ip) == 8, do: 128

  defp to_integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp to_integer(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, fn segment, acc -> acc <<< 16 ||| segment end)
end
