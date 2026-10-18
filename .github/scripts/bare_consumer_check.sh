#!/usr/bin/env bash
#
# Builds a throwaway consumer project that depends on :conduit_mcp and
# *nothing else*, then asserts the library behaves correctly with none of its
# optional dependencies present.
#
# This is the one configuration the main test suite can never cover: `optional:
# true` deps are fetched and compiled for the defining project, so every
# `if Code.ensure_loaded?(Dep)` guard in this repo's own suite evaluates true.
#
# Usage: .github/scripts/bare_consumer_check.sh [path-to-conduit-mcp-checkout]

set -euo pipefail

REPO_ROOT="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/../..}" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "conduit_mcp checkout: $REPO_ROOT"
echo "scratch consumer:     $WORKDIR"

mkdir -p "$WORKDIR/lib"

# Quoted heredoc + sed: nothing in this file interpolates, so a checkout path
# containing a quote cannot inject code into the generated mix.exs (which the
# following `mix deps.get` would then execute).
cat > "$WORKDIR/mix.exs" <<'EOF'
defmodule BareConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :bare_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:conduit_mcp, path: "@REPO_ROOT@"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
EOF

# '#' is rejected too: the substitution target sits inside an Elixir
# double-quoted string, where '#{...}' interpolates and needs neither a quote
# nor a backslash. A checkout at '/tmp/#{File.write!("/tmp/pwn","x")}' is a
# legal directory name that would execute on 'mix deps.get'.
if printf '%s' "$REPO_ROOT" | grep -q '["\\#]'; then
  echo "refusing to run: checkout path contains a quote, backslash or '#': $REPO_ROOT" >&2
  exit 1
fi

REPO_ROOT_ESCAPED="$(printf '%s' "$REPO_ROOT" | sed -e 's/[&/|]/\\&/g')"
sed -i.bak "s|@REPO_ROOT@|$REPO_ROOT_ESCAPED|" "$WORKDIR/mix.exs"
rm -f "$WORKDIR/mix.exs.bak"

cat > "$WORKDIR/lib/bare_consumer.ex" <<'EOF'
defmodule BareConsumer.Server do
  @moduledoc false
  use ConduitMcp.Server

  tool "ping", "Replies with pong" do
    handle(fn _conn, _params -> text("pong") end)
  end
end
EOF

# An MCP server on stdio for the client check: newline-delimited JSON-RPC in,
# one JSON line per reply out, through ConduitMcp.Handler.dispatch/3 (which
# serves both eras). check.exs starts it with `elixir -pa <every ebin>`.
cat > "$WORKDIR/stdio_server.exs" <<'EOF'
:ok = :logger.remove_handler(:default)
{:ok, _apps} = Application.ensure_all_started(:conduit_mcp)
:ok = :io.setopts(:standard_io, binary: true)

conn = %Plug.Conn{
  remote_ip: {127, 0, 0, 1},
  private: %{server_module: BareConsumer.Server, server_name: nil, server_version: nil, instructions: nil}
}

write = fn message -> IO.binwrite(:stdio, [JSON.encode!(message), ?\n]) end

# Nothing is ever published here: acknowledge a modern listen and stay silent.
ack = fn %ConduitMcp.StreamSpec{request_id: id, subscription: filter} ->
  ack = ConduitMcp.Notifications.subscriptions_acknowledged_notification(filter.ack)
  params = Map.get(ack, "params") || %{}
  meta = Map.put(Map.get(params, "_meta") || %{}, "io.modelcontextprotocol/subscriptionId", id)
  write.(Map.put(ack, "params", Map.put(params, "_meta", meta)))
end

loop = fn loop ->
  case IO.binread(:stdio, :line) do
    :eof ->
      System.halt(0)

    {:error, _reason} ->
      System.halt(1)

    line ->
      case String.trim_trailing(line) do
        "" ->
          :ok

        json ->
          case ConduitMcp.Handler.dispatch(JSON.decode!(json), BareConsumer.Server, conn) do
            {:reply, response} -> write.(response)
            {:stream, %ConduitMcp.StreamSpec{kind: :listen} = spec} -> ack.(spec)
            {:stream, spec} -> write.(ConduitMcp.StreamSpec.run(spec))
            :noreply -> :ok
          end
      end

      loop.(loop)
  end
end

loop.(loop)
EOF

cat > "$WORKDIR/check.exs" <<'EOF'
defmodule BareCheck do
  @moduledoc false

  import Plug.Test
  import Plug.Conn

  @oauth_auth [
    strategy: :oauth,
    issuer: "https://auth.example.com",
    audience: "https://mcp.example.com",
    key_provider:
      {ConduitMcp.OAuth.KeyProvider.JWKS,
       jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
  ]

  def run do
    absent!(ConduitMcp.Plugs.OAuth)
    absent!(ConduitMcp.OAuth.KeyProvider.JWKS)
    absent!(ConduitMcp.PromEx)
    absent!(ConduitMcp.Client.SchemaValidator.JSV)
    absent!(ConduitMcp.Client.HTTP)
    absent!(ConduitMcp.Client.Transport.StreamableHTTP.Exchange)
    absent!(ConduitMcp.Client.Transport.StreamableHTTP.Listener)

    # The OAuth client: everything that does HTTP needs :finch, and the
    # private_key_jwt signer needs :jose.
    absent!(ConduitMcp.Client.OAuth)
    absent!(ConduitMcp.Client.OAuth.Session)
    absent!(ConduitMcp.Client.OAuth.HTTP)
    absent!(ConduitMcp.Client.OAuth.Discovery.Fetch)
    absent!(ConduitMcp.Client.OAuth.Registration)
    absent!(ConduitMcp.Client.OAuth.TokenEndpoint)
    absent!(ConduitMcp.Client.OAuth.ClientCredentials)
    absent!(ConduitMcp.Client.OAuth.Loopback)
    absent!(ConduitMcp.Client.OAuth.ClientAssertion)

    present!(ConduitMcp.Plugs.Auth)
    present!(ConduitMcp.Transport.StreamableHTTP)
    present!(ConduitMcp.Transport.SSE)
    present!(ConduitMcp.OptionalDeps)
    present!(ConduitMcp.Client.Transport.StreamableHTTP)
    present!(ConduitMcp.Client.OAuth.Config)
    present!(ConduitMcp.Client.OAuth.TokenStore)
    present!(ConduitMcp.Client.OAuth.TokenStore.ETS)
    present!(ConduitMcp.Client.OAuth.CIMD)
    present!(ConduitMcp.Client.OAuth.Challenge)

    refute!(
      ConduitMcp.OptionalDeps.oauth_available?(),
      "OptionalDeps.oauth_available?/0 must be false without :joken"
    )

    oauth_init_raises!(ConduitMcp.Transport.StreamableHTTP)
    oauth_init_raises!(ConduitMcp.Transport.SSE)

    key_provider_raises!()
    client_validation_raises!()
    http_client_raises!()
    oauth_client_raises!()
    serves_without_optional_deps!()
    in_process_client_works!()
    stdio_client_works!()

    IO.puts("\nbare-consumer check: OK")
  end

  # --- assertions -------------------------------------------------------

  defp absent!(mod) do
    refute!(
      Code.ensure_loaded?(mod),
      "#{inspect(mod)} must NOT be compiled when its optional dep is absent"
    )

    IO.puts("  ok  #{inspect(mod)} absent")
  end

  defp present!(mod) do
    assert!(Code.ensure_loaded?(mod), "#{inspect(mod)} must always be compiled")
    IO.puts("  ok  #{inspect(mod)} present")
  end

  # `strategy: :oauth` must fail at init/1 with a message naming the missing
  # dep and the rebuild command — NOT fall through to Plugs.Auth's catch-all
  # and return a blanket 401 on every request.
  defp oauth_init_raises!(transport) do
    result =
      try do
        transport.init(server_module: BareConsumer.Server, auth: @oauth_auth)
        {:no_raise, nil}
      rescue
        e in ConduitMcp.OptionalDependencyError -> {:ok, Exception.message(e)}
        e -> {:wrong_error, e}
      end

    case result do
      {:ok, message} ->
        assert!(message =~ ":joken", "#{inspect(transport)} error must name :joken")

        assert!(
          message =~ "mix deps.compile conduit_mcp --force",
          "#{inspect(transport)} error must name the rebuild command"
        )

        IO.puts("  ok  #{inspect(transport)}.init/1 raises actionable OptionalDependencyError")

      {:no_raise, _} ->
        die("""
        #{inspect(transport)}.init/1 accepted strategy: :oauth without :joken.
        Every request will fall through to Plugs.Auth's catch-all and 401.
        """)

      {:wrong_error, e} ->
        die("#{inspect(transport)}.init/1 raised #{inspect(e.__struct__)}, expected \
ConduitMcp.OptionalDependencyError:\n#{Exception.message(e)}")
    end
  end

  # A JWKS key provider must be rejected at init/1 rather than becoming an
  # UndefinedFunctionError on the first authenticated request.
  defp key_provider_raises!() do
    try do
      ConduitMcp.OptionalDeps.validate_key_provider!(ConduitMcp.OAuth.KeyProvider.JWKS)
      die("OptionalDeps.validate_key_provider!/1 accepted an absent JWKS provider")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        message = Exception.message(e)
        assert!(message =~ ":req", "JWKS provider error must name :req")

        assert!(
          message =~ "mix deps.compile conduit_mcp --force",
          "JWKS provider error must name the rebuild command"
        )

        IO.puts("  ok  absent JWKS key provider rejected at init/1")
    end
  end

  # A client asking for JSON Schema validation must fail when its options are
  # validated, naming :jsv, never on the first call.
  defp client_validation_raises!() do
    refute!(
      ConduitMcp.OptionalDeps.jsv_available?(),
      "OptionalDeps.jsv_available?/0 must be false without :jsv"
    )

    try do
      ConduitMcp.Client.Config.new!(
        name: :bare,
        transport: {ConduitMcp.Client.Transport.InProcess, server: BareConsumer.Server},
        validate: [arguments: true]
      )

      die("ConduitMcp.Client accepted validate: without :jsv")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        assert!(Exception.message(e) =~ ":jsv", "validation error must name :jsv")
        IO.puts("  ok  client validate: rejected at init without :jsv")
    end

    # Everything else about governance needs no optional dep.
    ConduitMcp.Client.Config.new!(
      name: :bare,
      transport: {ConduitMcp.Client.Transport.InProcess, server: BareConsumer.Server},
      policy: [allow: ["*"]],
      hooks: [pre_tool_call: [{:all, fn _call, _ctx -> :cont end}]]
    )

    IO.puts("  ok  client policy and hooks need no optional deps")
  end

  # The client's HTTP transport needs :finch; without it the client must
  # refuse to start (child_spec/1 validates the transport options), never
  # fail per request.
  defp http_client_raises!() do
    try do
      ConduitMcp.Client.child_spec(
        name: :bare,
        transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/"}
      )

      die("ConduitMcp.Client accepted the Streamable HTTP transport without :finch")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        message = Exception.message(e)
        assert!(message =~ ":finch", "HTTP transport error must name :finch")

        assert!(
          message =~ "mix deps.compile conduit_mcp --force",
          "HTTP transport error must name the rebuild command"
        )

        IO.puts("  ok  Streamable HTTP client transport without :finch rejected at start")
    end

    try do
      ConduitMcp.OptionalDeps.finch!()
      die("OptionalDeps.finch!/0 returned without :finch")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        assert!(Exception.message(e) =~ ":finch", "finch!/0 must name :finch")
        IO.puts("  ok  ConduitMcp.Client.HTTP without :finch names :finch")
    end
  end

  # auth: {:oauth, ...} without :finch must refuse to start, naming :finch,
  # and so must the OAuth runtime and the private_key_jwt signer on their own.
  defp oauth_client_raises!() do
    try do
      ConduitMcp.Client.child_spec(
        name: :bare_oauth,
        transport:
          {ConduitMcp.Client.Transport.StreamableHTTP,
           url: "https://mcp.example.com/",
           auth: {:oauth, redirect_uri: "http://127.0.0.1:33418/callback"}}
      )

      die("ConduitMcp.Client accepted auth: {:oauth, ...} without :finch")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        assert!(Exception.message(e) =~ ":finch", "OAuth client error must name :finch")
        IO.puts("  ok  auth: {:oauth, ...} without :finch rejected at start")
    end

    try do
      ConduitMcp.OptionalDeps.oauth_client!()
      die("OptionalDeps.oauth_client!/0 returned without :finch")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        assert!(Exception.message(e) =~ ":finch", "oauth_client!/0 must name :finch")
        IO.puts("  ok  OptionalDeps.oauth_client!/0 names :finch")
    end

    try do
      ConduitMcp.OptionalDeps.client_assertion!()
      die("OptionalDeps.client_assertion!/0 returned without :jose")
    rescue
      e in ConduitMcp.OptionalDependencyError ->
        assert!(Exception.message(e) =~ ":jose", "client_assertion!/0 must name :jose")
        IO.puts("  ok  private_key_jwt without :jose names :jose")
    end
  end

  # The library must still work for everything that needs no optional dep.
  defp serves_without_optional_deps!() do
    opts = ConduitMcp.Transport.StreamableHTTP.init(server_module: BareConsumer.Server)
    conn = ConduitMcp.Transport.StreamableHTTP.call(conn(:get, "/health"), opts)
    assert!(conn.status == 200, "GET /health must return 200, got #{inspect(conn.status)}")

    body =
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> ConduitMcp.Transport.StreamableHTTP.call(opts)

    assert!(conn.status == 200, "POST tools/list must return 200, got #{inspect(conn.status)}")
    decoded = JSON.decode!(conn.resp_body)
    assert!(is_map(decoded["result"]), "tools/list must return a result, got #{conn.resp_body}")
    IO.puts("  ok  transport serves requests with no optional deps installed")
  end

  # The client needs no optional dep for the InProcess and stdio transports.
  defp in_process_client_works!() do
    {:ok, sup} =
      ConduitMcp.Client.start_link(
        name: :bare_in_process,
        transport: {ConduitMcp.Client.Transport.InProcess, server: BareConsumer.Server}
      )

    client_round_trip!(:bare_in_process, "InProcess")
    Supervisor.stop(sup)
  end

  defp stdio_client_works!() do
    elixir = Path.expand("../../bin/elixir", to_string(:code.lib_dir(:elixir)))
    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    erts_bin = Path.join(to_string(:code.root_dir()), "bin")

    {:ok, sup} =
      ConduitMcp.Client.start_link(
        name: :bare_stdio,
        transport:
          {ConduitMcp.Client.Transport.Stdio,
           command: if(File.regular?(elixir), do: elixir, else: "elixir"),
           args: Enum.flat_map(ebins, &["-pa", &1]) ++ [Path.expand("stdio_server.exs")],
           env: %{"PATH" => erts_bin <> ":" <> System.get_env("PATH", "")}}
      )

    client_round_trip!(:bare_stdio, "stdio")
    Supervisor.stop(sup)
  end

  defp client_round_trip!(client, label) do
    case ConduitMcp.Client.await_ready(client, 30_000) do
      :ok -> :ok
      {:error, error} -> die("#{label} client not ready: #{Exception.message(error)}")
    end

    {:ok, tools} = ConduitMcp.Client.list_all_tools(client)
    assert!(Enum.map(tools, & &1.name) == ["ping"], "#{label} client tools: #{inspect(tools)}")

    {:ok, result} = ConduitMcp.Client.call_tool(client, "ping")
    text = Enum.map_join(result.content, "", &(&1["text"] || ""))
    assert!(not result.is_error and text == "pong", "#{label} ping returned #{inspect(result)}")

    {:ok, era} = ConduitMcp.Client.era(client)
    IO.puts("  ok  #{label} client works without optional deps (#{era} era)")
  end

  # --- tiny assertion kit (no ExUnit in a bare mix run) -----------------

  defp assert!(true, _message), do: :ok
  defp assert!(_falsy, message), do: die(message)

  defp refute!(false, _message), do: :ok
  defp refute!(_truthy, message), do: die(message)

  defp die(message) do
    IO.puts(:stderr, "\nFAIL: #{message}")
    System.halt(1)
  end
end

BareCheck.run()
EOF

cd "$WORKDIR"
mix deps.get

# `--warnings-as-errors` covers only the consumer's own code, so check the
# library's compile output here: a call into a module that is absent without
# its optional dep (where the compiler types the module as a literal) warns
# in every consumer that lacks that dep.
mix deps.compile 2>&1 | tee deps_compile.log
if grep -q 'lib/conduit_mcp/' deps_compile.log; then
  echo "FAIL: conduit_mcp compiled with warnings in a consumer without optional deps" >&2
  exit 1
fi
echo "  ok  conduit_mcp compiles without warnings in a bare consumer"

mix compile --warnings-as-errors
mix run check.exs
