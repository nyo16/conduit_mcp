defmodule ConduitMcp.Client.OAuth.Resource do
  @moduledoc """
  The canonical resource URI of an MCP server: the value sent as the RFC 8707
  `resource` parameter in authorization and token requests, compared exactly
  against Protected Resource Metadata `resource`, and used in token-store keys.

      iex> ConduitMcp.Client.OAuth.Resource.canonical("HTTPS://MCP.Example.com:443/mcp/#frag")
      {:ok, "https://mcp.example.com/mcp"}

  `canonical/2` applies the MCP authorization spec's rules (*Canonical Server
  URI*):

    * the scheme and host are lowercased;
    * a default port (`443` for `https`, `80` for `http`) is dropped, any other
      port is kept;
    * the fragment is removed;
    * trailing slashes are removed (`https://ex.com/` → `https://ex.com`); the
      rest of the path and any query are kept byte for byte (percent-encoding
      is not normalized);
    * the scheme must be `https`. Plain `http` is accepted only for a loopback
      host (`localhost`, `127.0.0.0/8`, `::1`) and only with
      `allow_insecure: true`, for local development and tests;
    * a URL without a host or with user info is refused.
  """

  alias ConduitMcp.Client.OAuth.{Error, URL}

  @doc """
  Returns the canonical form of `url`.

  ## Options

    * `:allow_insecure` - admit `http` on a loopback host (default `false`).

  Errors: `:invalid_url` (unparsable, no host, user info) and `:insecure_url`.
  """
  @spec canonical(String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def canonical(url, opts \\ []) do
    with {:ok, uri} <- URL.parse(url, opts) do
      {:ok, URL.origin(uri) <> URL.trimmed_path(uri) <> query(uri)}
    end
  end

  defp query(%URI{query: query}) when query in [nil, ""], do: ""
  defp query(%URI{query: query}), do: "?" <> query
end
