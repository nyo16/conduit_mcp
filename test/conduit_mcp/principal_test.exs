defmodule ConduitMcp.PrincipalTest do
  # async: false — touches the global :conduit_mcp_tasks table, which
  # test/conduit_mcp/handler_tasks_test.exs wipes wholesale. (The `tasks/*`
  # tests were extracted out of handler_test.exs, which no longer touches it.)
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.Auth
  alias ConduitMcp.Plugs.OAuth
  alias ConduitMcp.Principal
  alias ConduitMcp.Tasks

  @rsa_key JOSE.JWK.generate_key({:rsa, 2048})
  @rsa_key_map @rsa_key |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "principal-key")
  @rsa_public_key @rsa_key
                  |> JOSE.JWK.to_public()
                  |> JOSE.JWK.to_map()
                  |> elem(1)
                  |> Map.put("kid", "principal-key")

  @oauth_opts OAuth.init(
                issuer: "https://auth.example.com",
                audience: "https://mcp.example.com",
                key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
              )

  defp oauth_token(sub, extra) do
    signer = Joken.Signer.create("RS256", @rsa_key_map)

    claims =
      Map.merge(
        %{
          "iss" => "https://auth.example.com",
          "aud" => "https://mcp.example.com",
          "sub" => sub,
          "exp" => System.system_time(:second) + 3600,
          "iat" => System.system_time(:second),
          "jti" => Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        },
        extra
      )

    {:ok, token, _} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp oauth_request(sub, extra \\ %{}) do
    conn(:post, "/")
    |> put_req_header("authorization", "Bearer #{oauth_token(sub, extra)}")
    |> OAuth.call(@oauth_opts)
  end

  describe "OAuth principal" do
    test "id is the sub claim, not the volatile claims map" do
      conn = oauth_request("user-123", %{"scope" => "read write"})

      refute conn.halted

      assert %{id: "sub:user-123", strategy: :oauth, scopes: ["read", "write"]} =
               Principal.get(conn)

      assert Principal.id(conn) == "sub:user-123"
      assert Principal.scopes(conn) == ["read", "write"]
    end

    test "two requests by the same subject produce the same id despite differing claims" do
      a = oauth_request("user-123")
      b = oauth_request("user-123")

      # The claims maps genuinely differ (jti is per-token) — this is exactly
      # why keying ownership on the claims map never matched.
      refute a.assigns[:oauth_claims] == b.assigns[:oauth_claims]
      assert Principal.id(a) == Principal.id(b)
    end

    test "distinct subjects produce distinct ids" do
      assert Principal.id(oauth_request("alice")) != Principal.id(oauth_request("bob"))
    end
  end

  describe "static-auth principal" do
    test "bearer_token derives a stable id from the credential" do
      opts = Auth.init(strategy: :bearer_token, token: "shared-secret")

      a = conn(:post, "/") |> put_req_header("authorization", "Bearer shared-secret")
      b = conn(:post, "/") |> put_req_header("authorization", "Bearer shared-secret")

      id_a = Auth.call(a, opts) |> Principal.id()
      id_b = Auth.call(b, opts) |> Principal.id()

      assert is_binary(id_a)
      assert id_a == id_b
      # The credential must not be echoed back in the identity.
      refute id_a =~ "shared-secret"
    end

    test ":principal_id overrides the derived id" do
      opts = Auth.init(strategy: :bearer_token, token: "shared-secret", principal_id: "ci-bot")

      conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Bearer shared-secret")
        |> Auth.call(opts)

      assert Principal.id(conn) == "ci-bot"
      assert Principal.get(conn).strategy == :bearer_token
    end

    test ":function strategy derives the id from the verifier's return value" do
      opts =
        Auth.init(
          strategy: :function,
          verify: fn "tok-" <> id -> {:ok, %{id: id, scopes: ["read"]}} end
        )

      conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Bearer tok-42")
        |> Auth.call(opts)

      assert Principal.id(conn) == "42"
      assert Principal.scopes(conn) == ["read"]
      assert Principal.get(conn).user == %{id: "42", scopes: ["read"]}
    end

    test "an unauthenticated conn has no principal" do
      assert Principal.get(conn(:post, "/")) == nil
      assert Principal.id(conn(:post, "/")) == nil
      assert Principal.scopes(conn(:post, "/")) == []
    end
  end

  describe "task ownership across requests" do
    test "an OAuth subject can retrieve on request B a task created on request A" do
      sub = "owner-oauth-#{System.unique_integer([:positive])}"
      request_a = oauth_request(sub)
      request_b = oauth_request(sub)

      owner_a = Tasks.owner(request_a)
      owner_b = Tasks.owner(request_b)

      assert is_binary(owner_a)
      assert owner_a == owner_b

      task_id = Tasks.generate_id()
      assert {:ok, _task} = Tasks.create(task_id, %{}, owner_a)

      assert {:ok, task} = Tasks.get(task_id, owner_b)
      assert task["task_id"] == task_id
    end

    test "a different OAuth subject cannot retrieve it" do
      mine = oauth_request("mine-#{System.unique_integer([:positive])}")
      theirs = oauth_request("theirs-#{System.unique_integer([:positive])}")

      task_id = Tasks.generate_id()
      {:ok, _} = Tasks.create(task_id, %{}, Tasks.owner(mine))

      assert {:error, :not_found} = Tasks.get(task_id, Tasks.owner(theirs))
    end

    test "a static-auth principal can retrieve its own task on a later request" do
      opts = Auth.init(strategy: :api_key, api_key: "key-abc", principal_id: "svc-1")

      request = fn ->
        conn(:post, "/")
        |> put_req_header("x-api-key", "key-abc")
        |> Auth.call(opts)
      end

      owner = Tasks.owner(request.())
      assert owner == "svc-1"

      task_id = Tasks.generate_id()
      {:ok, _} = Tasks.create(task_id, %{}, owner)

      assert {:ok, _task} = Tasks.get(task_id, Tasks.owner(request.()))
    end

    test "owner/1 still accepts a bare scalar :current_user for back-compat" do
      conn = conn(:post, "/") |> assign(:current_user, "legacy-id")
      assert Tasks.owner(conn) == "legacy-id"
    end

    test "owner/1 refuses to key on a non-scalar :current_user" do
      # This is the shape that silently 404'd the owner's own task.
      conn = conn(:post, "/") |> assign(:current_user, %{claims: %{"exp" => 1}})
      assert Tasks.owner(conn) == nil
    end
  end

  describe "put/2 normalises :id" do
    test "a non-scalar id becomes nil rather than violating id/1's @spec" do
      # `put/2` is public, so an application writing its own principal can hand
      # us anything. Before normalising here, `Principal.put(conn, %{id: pid})`
      # produced a principal whose `id/1` returned a pid — which then flowed
      # into task ownership, the rate-limit bucket key and scope checks, and
      # made `rate_limit_key/1` raise Protocol.UndefinedError *inside the
      # request pipeline*.
      conn = Principal.put(conn(:post, "/"), %{id: self(), strategy: :custom})

      assert Principal.id(conn) == nil
      # Falls back to the IP bucket instead of raising.
      assert Principal.rate_limit_key(conn) == "127.0.0.1"
    end

    test "scalar ids survive, and derivable shapes are derived" do
      assert Principal.put(conn(:post, "/"), %{id: "u1"}) |> Principal.id() == "u1"
      assert Principal.put(conn(:post, "/"), %{id: 42}) |> Principal.id() == "42"
      assert Principal.put(conn(:post, "/"), %{id: :svc}) |> Principal.id() == "svc"
      assert Principal.put(conn(:post, "/"), %{}) |> Principal.id() == nil

      # `derive_id/1` digs for a subject, so a claims-shaped id is normalised
      # rather than rejected.
      assert Principal.put(conn(:post, "/"), %{id: %{sub: "x"}}) |> Principal.id() == "x"
      assert Principal.put(conn(:post, "/"), %{id: %{"id" => 7}}) |> Principal.id() == "7"

      # A map with no subject key has no scalar identity at all.
      assert Principal.put(conn(:post, "/"), %{id: %{"exp" => 1}}) |> Principal.id() == nil
    end

    test "rate_limit_key/1 cannot raise for any principal put/2 accepts" do
      for id <- [nil, "u1", 42, :svc, %{}, {1, 2}, [1], self()] do
        conn = Principal.put(conn(:post, "/"), %{id: id})
        assert is_binary(Principal.rate_limit_key(conn))
      end
    end
  end

  describe "derive_id/1 namespacing" do
    defmodule User do
      @moduledoc false
      defstruct [:id]
    end

    defmodule ApiClient do
      @moduledoc false
      defstruct [:id]
    end

    test "two struct types sharing a primary key are different principals" do
      # The ordinary multi-tenant shape: a `:verify` function returning
      # %User{id: 42} for a human and %ApiClient{id: 42} for a service account,
      # each with its own integer sequence. Both used to derive "42", and task
      # ownership is an exact string compare — so the service account read and
      # cancelled the human's tasks. Same defect class RC7 closed on the OAuth
      # side by prefixing the producing claim.
      user = Principal.derive_id(%User{id: 42})
      client = Principal.derive_id(%ApiClient{id: 42})

      assert is_binary(user)
      assert is_binary(client)
      refute user == client

      assert user =~ "User"
      assert user =~ "42"
    end

    test "a struct with no scalar identity still derives nil" do
      assert Principal.derive_id(%User{id: nil}) == nil
      assert Principal.derive_id(%User{id: %{}}) == nil
    end

    test "plain maps and scalars are unchanged" do
      assert Principal.derive_id(%{id: "u1"}) == "u1"
      assert Principal.derive_id(%{"sub" => "s1"}) == "s1"
      assert Principal.derive_id("bare") == "bare"
      assert Principal.derive_id(7) == "7"
    end
  end

  describe "client_ip/1" do
    test "renders IPv4 and IPv6 addresses" do
      assert Principal.client_ip(%{remote_ip: {127, 0, 0, 1}}) == "127.0.0.1"
      assert Principal.client_ip(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}) == "::1"
    end

    test "returns \"unknown\" for a malformed remote_ip instead of raising" do
      assert Principal.client_ip(%{remote_ip: {1, 2, 3}}) == "unknown"
      assert Principal.client_ip(%{remote_ip: nil}) == "unknown"
      assert Principal.client_ip(%{}) == "unknown"
    end
  end

  describe "derive_id/1" do
    test "prefers id, then sub, in atom then string form" do
      assert Principal.derive_id(%{id: "a"}) == "a"
      assert Principal.derive_id(%{"id" => "b"}) == "b"
      assert Principal.derive_id(%{sub: "c"}) == "c"
      assert Principal.derive_id(%{"sub" => "d"}) == "d"
      assert Principal.derive_id(%{id: 7}) == "7"
      assert Principal.derive_id("plain") == "plain"
      assert Principal.derive_id(:atom_id) == "atom_id"
    end

    test "returns nil when no stable scalar is available" do
      assert Principal.derive_id(%{authenticated: true}) == nil
      assert Principal.derive_id(%{id: %{nested: true}}) == nil
      assert Principal.derive_id(nil) == nil
    end
  end
end
