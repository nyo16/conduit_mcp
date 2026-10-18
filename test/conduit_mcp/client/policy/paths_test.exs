defmodule ConduitMcp.Client.Policy.PathsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Policy.Paths

  doctest ConduitMcp.Client.Policy.Paths

  @root "/data"

  describe "canonicalize/3" do
    test "resolves relative paths against the root and normalizes lexically" do
      for {path, expected} <- [
            {"x", "/data/x"},
            {"./x/", "/data/x"},
            {"x//y/./z", "/data/x/y/z"},
            {"x/../y", "/data/y"},
            {"../etc/passwd", "/etc/passwd"},
            {"/data/../etc", "/etc"},
            {"/../../..", "/"},
            {"~/x", "/data/~/x"},
            {"", "/data"}
          ] do
        assert Paths.canonicalize(path, @root) == {:ok, expected}, inspect(path)
      end
    end

    test "fails on non-strings, NUL bytes, invalid UTF-8 and relative roots" do
      assert Paths.canonicalize(1, @root) == {:error, :not_a_string}
      assert Paths.canonicalize(nil, @root) == {:error, :not_a_string}
      assert Paths.canonicalize("a" <> <<0>>, @root) == {:error, :nul_byte}
      assert Paths.canonicalize(<<0xFF>>, @root) == {:error, :invalid_unicode}
      assert Paths.canonicalize("x", "data") == {:error, :relative_root}
    end

    test "normalizes to NFC" do
      decomposed = "cafe\u0301"
      assert Paths.canonicalize(decomposed, @root) == {:ok, "/data/caf\u00e9"}
    end

    test "an injected resolver sees the lexical path, and failures fail" do
      links = %{"/data/link" => "/etc", "/data" => "/data"}

      resolve = fn path ->
        case Map.fetch(links, path) do
          {:ok, target} -> {:ok, target}
          :error -> {:ok, path}
        end
      end

      assert Paths.canonicalize("link", @root, resolve: resolve) == {:ok, "/etc"}
      refute Paths.inside?("link", @root, resolve: resolve)
      assert Paths.inside?("plain", @root, resolve: resolve)

      for bad <- [fn _ -> {:error, :enoent} end, fn _ -> {:ok, "relative"} end, fn _ -> :ok end] do
        assert Paths.canonicalize("/x", "/", resolve: bad) == {:error, :resolve_failed}
      end
    end
  end

  describe "inside?/3" do
    test "containment is by whole segments" do
      assert Paths.inside?("/data", @root)
      assert Paths.inside?("/data/a/b", @root)
      refute Paths.inside?("/database", @root)
      refute Paths.inside?("/dat", @root)
      assert Paths.inside?("/anything", "/")
    end

    property "an inside path always canonicalizes to the root or below it" do
      segment =
        one_of([member_of([".", "..", "", "~", "data"]), string(:alphanumeric, max_length: 4)])

      check all(
              segments <- list_of(segment, max_length: 8),
              absolute? <- boolean()
            ) do
        path = if(absolute?, do: "/", else: "") <> Enum.join(segments, "/")
        {:ok, canonical} = Paths.canonicalize(path, @root)

        assert Paths.inside?(path, @root) ==
                 (canonical == @root or String.starts_with?(canonical, @root <> "/"))

        refute canonical =~ ~r{(^|/)\.\.?(/|$)}
      end
    end
  end

  describe "inside/3 and escapes/3 predicates" do
    test "select an argument by key or path, and check list values element-wise" do
      inside = Paths.inside(["files", 0, "path"], @root)
      escapes = Paths.escapes("paths", @root)

      assert inside.(%{"files" => [%{"path" => "a"}]})
      refute inside.(%{"files" => [%{"path" => "../a"}]})
      refute inside.(%{"files" => []})
      refute inside.(%{})

      refute escapes.(%{"paths" => ["a", "/data/b"]})
      assert escapes.(%{"paths" => ["a", "/etc"]})
      assert escapes.(%{"paths" => ["a", 1]})
      refute escapes.(%{"paths" => []})
      refute escapes.(%{})
      assert escapes.(%{"paths" => nil})
    end

    test "raise at build time on a bad root or selector" do
      assert_raise ArgumentError, ~r/invalid path root/, fn -> Paths.inside("p", "rel") end
      assert_raise ArgumentError, ~r/path selector/, fn -> Paths.escapes([], "/") end
      assert_raise ArgumentError, ~r/path selector/, fn -> Paths.escapes([:p], "/") end
    end
  end
end
