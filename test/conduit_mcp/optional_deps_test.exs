defmodule ConduitMcp.OptionalDepsTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.OptionalDependencyError
  alias ConduitMcp.OptionalDeps

  defmodule NotAKeyProvider do
    @moduledoc false
    def unrelated, do: :ok
  end

  defmodule HalfKeyProvider do
    @moduledoc false
    # `fetch_keys/1` only. This is the shape that used to pass `init/1` and
    # then raise UndefinedFunctionError on the first `kid`-bearing token.
    def fetch_keys(_config), do: {:ok, []}
  end

  describe "validate_key_provider!/1" do
    test "accepts a module exporting fetch_keys/1" do
      assert :ok = OptionalDeps.validate_key_provider!(ConduitMcp.OAuth.KeyProvider.Static)
    end

    test "rejects a module that does not export fetch_keys/1" do
      assert_raise ArgumentError, ~r/does not export fetch_keys\/1/, fn ->
        OptionalDeps.validate_key_provider!(NotAKeyProvider)
      end
    end

    test "rejects a module that exports fetch_keys/1 but not fetch_key/2" do
      # `fetch_signing_key/2` dispatches on the token's `kid` header, so
      # `fetch_key/2` is the branch every token from a real JWKS-publishing
      # authorization server takes. Validating only `fetch_keys/1` moved
      # nothing to boot time for the common case.
      assert_raise ArgumentError, ~r/does not export fetch_key\/2/, fn ->
        OptionalDeps.validate_key_provider!(HalfKeyProvider)
      end
    end

    test "accepts the built-in providers, which implement both callbacks" do
      assert :ok = OptionalDeps.validate_key_provider!(ConduitMcp.OAuth.KeyProvider.Static)
      assert :ok = OptionalDeps.validate_key_provider!(ConduitMcp.OAuth.KeyProvider.JWKS)
    end

    test "rejects a module that cannot be loaded" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        OptionalDeps.validate_key_provider!(ConduitMcp.NoSuchKeyProvider)
      end
    end
  end

  describe "OptionalDependencyError" do
    test "names both the dependency and the rebuild command" do
      error =
        OptionalDependencyError.exception(
          feature: "The :oauth auth strategy",
          module: ConduitMcp.Plugs.OAuth,
          deps: [{:joken, "~> 2.6"}, {:jose, "~> 1.11"}]
        )

      message = Exception.message(error)

      assert message =~ "The :oauth auth strategy"
      assert message =~ "ConduitMcp.Plugs.OAuth"
      assert message =~ ~s({:joken, "~> 2.6"})
      assert message =~ ~s({:jose, "~> 1.11"})
      assert message =~ "mix deps.compile conduit_mcp --force"
    end

    test "uses singular phrasing for a single dependency" do
      message =
        OptionalDependencyError.exception(
          feature: "The JWKS key provider",
          module: ConduitMcp.OAuth.KeyProvider.JWKS,
          deps: [{:req, "~> 0.6.1 or ~> 0.7"}]
        )
        |> Exception.message()

      assert message =~ ":req is available"
    end
  end

  describe "availability in this build" do
    test "optional deps are present for the library's own suite" do
      # This suite always compiles with every optional dep installed, which is
      # exactly why the absent-dep configuration needs the bare-consumer CI
      # job rather than an assertion here.
      assert OptionalDeps.oauth_available?()
      assert OptionalDeps.oauth_plug!() == ConduitMcp.Plugs.OAuth
      assert OptionalDeps.prom_ex_plugin!() == ConduitMcp.PromEx
    end
  end
end
