defmodule ConduitMcp.Client.OAuth.CIMD do
  @moduledoc """
  Client ID Metadata Documents (the MCP authorization spec's preferred
  client registration; `draft-ietf-oauth-client-id-metadata-document`).

  With CIMD the client id **is** an `https` URL with a path. The
  authorization server fetches that URL and reads the client's metadata
  from it, so no registration request is ever made and the id works with
  every authorization server that supports CIMD (it is portable, unlike a
  dynamically registered one).

  The library never serves the document: the host publishes it at the
  configured `:client_metadata_url`, for example from a Phoenix controller
  or a static file:

      ConduitMcp.Client.OAuth.CIMD.document(
        client_id: "https://app.example.com/oauth/client.json",
        client_name: "My Agent",
        redirect_uris: ["http://127.0.0.1:33418/callback"]
      )
      |> JSON.encode!()

  The client uses CIMD when the authorization server's metadata has
  `client_id_metadata_document_supported: true` and no pre-registered
  client exists for that issuer (see `ConduitMcp.Client.OAuth`).
  """

  @doc """
  Whether `url` can be a CIMD client id: an absolute `https` URL with a
  host, a path other than `/`, and no user info or fragment.

      iex> ConduitMcp.Client.OAuth.CIMD.valid_url?("https://app.example.com/oauth/client.json")
      true
      iex> ConduitMcp.Client.OAuth.CIMD.valid_url?("https://app.example.com/")
      false
  """
  @spec valid_url?(term()) :: boolean()
  def valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, path: path, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" and is_binary(path) ->
        String.trim(path, "/") != ""

      _other ->
        false
    end
  end

  def valid_url?(_url), do: false

  @doc """
  The metadata document for `client_id` (string-keyed, ready for
  `JSON.encode!/1`).

  ## Options

    * `:client_id` (required) - the URL the document is served at.
    * `:client_name` (required) - shown to the user.
    * `:redirect_uris` (required) - every redirect URI the client uses.
    * `:application_type` - `:native` or `:web`.
    * any other string-valued RFC 7591 field (`:client_uri`, `:logo_uri`,
      `:tos_uri`, `:policy_uri`, ...) is copied as is.

  The document always declares `grant_types: ["authorization_code",
  "refresh_token"]`, `response_types: ["code"]` and
  `token_endpoint_auth_method: "none"`. Raises `ArgumentError` on an
  invalid `:client_id` or a missing required option.
  """
  @spec document(keyword()) :: %{String.t() => term()}
  def document(opts) when is_list(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    name = Keyword.fetch!(opts, :client_name)
    redirect_uris = Keyword.fetch!(opts, :redirect_uris)

    if not valid_url?(client_id),
      do: raise(ArgumentError, "a CIMD client_id must be an https URL with a path")

    extra =
      opts
      |> Keyword.drop([:client_id, :client_name, :redirect_uris])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), stringify(value)} end)

    Map.merge(extra, %{
      "client_id" => client_id,
      "client_name" => name,
      "redirect_uris" => redirect_uris,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    })
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
