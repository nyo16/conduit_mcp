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

    present!(ConduitMcp.Plugs.Auth)
    present!(ConduitMcp.Transport.StreamableHTTP)
    present!(ConduitMcp.Transport.SSE)
    present!(ConduitMcp.OptionalDeps)

    refute!(
      ConduitMcp.OptionalDeps.oauth_available?(),
      "OptionalDeps.oauth_available?/0 must be false without :joken"
    )

    oauth_init_raises!(ConduitMcp.Transport.StreamableHTTP)
    oauth_init_raises!(ConduitMcp.Transport.SSE)

    key_provider_raises!()
    serves_without_optional_deps!()

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
mix compile --warnings-as-errors
mix run check.exs
