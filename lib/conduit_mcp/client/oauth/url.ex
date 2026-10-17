defmodule ConduitMcp.Client.OAuth.URL do
  @moduledoc false
  # Shared URL rules for the OAuth helpers. `parse/2` accepts an absolute
  # `https` URL (or `http` on a loopback host when `:allow_insecure` is true),
  # rejects user info and missing hosts, and returns the `URI` with the scheme
  # and host lowercased and a default port dropped (`port: nil`). It does no
  # DNS and no address checks: server-originated URLs still go through
  # `ConduitMcp.Client.URLPolicy` before they are fetched.

  alias ConduitMcp.Client.OAuth.Error

  @spec parse(term(), keyword()) :: {:ok, URI.t()} | {:error, Error.t()}
  def parse(url, opts \\ [])

  def parse(url, opts) when is_binary(url) do
    with {:ok, uri} <- new(url),
         {:ok, uri} <- normalize(uri) do
      check_scheme(uri, Keyword.get(opts, :allow_insecure, false))
    end
  end

  def parse(_url, _opts), do: Error.error(:invalid_url, :not_a_string)

  # `localhost`, `127.0.0.0/8` or `::1`.
  @spec loopback?(String.t() | nil) :: boolean()
  def loopback?("localhost"), do: true

  def loopback?(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  def loopback?(_host), do: false

  # `scheme://host[:port]`, bracketing IPv6 literals.
  @spec origin(URI.t()) :: String.t()
  def origin(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    port = if port, do: ":" <> Integer.to_string(port), else: ""
    scheme <> "://" <> host <> port
  end

  # The path with every trailing slash removed ("" for the root).
  @spec trimmed_path(URI.t()) :: String.t()
  def trimmed_path(%URI{path: nil}), do: ""
  def trimmed_path(%URI{path: path}), do: String.trim_trailing(path, "/")

  defp new(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> Error.error(:invalid_url, :unparsable)
    end
  end

  defp normalize(%URI{scheme: nil}), do: Error.error(:invalid_url, :not_absolute)
  defp normalize(%URI{userinfo: info}) when info != nil, do: Error.error(:invalid_url, :userinfo)

  defp normalize(%URI{scheme: scheme, host: host, port: port} = uri) do
    scheme = String.downcase(scheme, :ascii)

    if is_binary(host) and host != "" do
      port = if port == URI.default_port(scheme), do: nil, else: port
      {:ok, %{uri | scheme: scheme, host: String.downcase(host, :ascii), port: port}}
    else
      {:ok, %{uri | scheme: scheme, host: nil}}
    end
  end

  defp check_scheme(%URI{scheme: "https", host: nil}, _insecure),
    do: Error.error(:invalid_url, :missing_host)

  defp check_scheme(%URI{scheme: "https"} = uri, _insecure), do: {:ok, uri}

  defp check_scheme(%URI{scheme: "http", host: host} = uri, true) do
    if loopback?(host), do: {:ok, uri}, else: Error.error(:insecure_url, "http")
  end

  defp check_scheme(%URI{scheme: scheme}, _insecure), do: Error.error(:insecure_url, scheme)
end
