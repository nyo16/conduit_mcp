defmodule ConduitMcp.HeadersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Headers

  @max_safe 9_007_199_254_740_991

  defp sentinel?(value),
    do: String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")

  defp header_safe?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))
  end

  describe "encode_value/1 and decode_value/1 properties" do
    property "arbitrary UTF-8 strings round-trip and encode to header-safe ASCII" do
      check all(s <- StreamData.string(:utf8)) do
        encoded = Headers.encode_value(s)
        assert Headers.decode_value(encoded) == {:ok, s}
        assert header_safe?(encoded)
        refute String.contains?(encoded, ["\r", "\n", "\0"])
      end
    end

    property "ASCII strings with whitespace, controls and sentinel look-alikes round-trip" do
      generator =
        StreamData.one_of([
          StreamData.string(:ascii),
          StreamData.string(:printable),
          StreamData.string(Enum.to_list(0..127)),
          StreamData.map(StreamData.string(:alphanumeric), &(" " <> &1)),
          StreamData.map(StreamData.string(:alphanumeric), &(&1 <> "\t")),
          StreamData.map(StreamData.string(:printable), &("=?base64?" <> &1 <> "?=")),
          StreamData.map(StreamData.string(:alphanumeric), &("=?" <> &1 <> "?="))
        ])

      check all(s <- generator) do
        encoded = Headers.encode_value(s)
        assert Headers.decode_value(encoded) == {:ok, s}
        assert header_safe?(encoded)
        refute String.starts_with?(encoded, " ") or String.ends_with?(encoded, " ")
      end
    end

    property "plain printable ASCII without edge spaces or sentinel shape passes through" do
      check all(
              s <- StreamData.string(Enum.to_list(0x21..0x7E), min_length: 1),
              not (String.starts_with?(s, "=?") and String.ends_with?(s, "?="))
            ) do
        assert Headers.encode_value(s) == s
      end
    end

    property "JS-safe integers round-trip and match integer and float body values" do
      check all(i <- StreamData.integer(-@max_safe..@max_safe)) do
        encoded = Headers.encode_value(i)
        assert {:ok, ^encoded} = Headers.decode_value(encoded)
        assert Headers.value_matches?(encoded, i)
        assert Headers.value_matches?(encoded, i * 1.0)
        refute Headers.value_matches?(encoded, i + 1)
      end
    end

    # HT-12: whatever a tool argument holds, its header value cannot split
    # or truncate the header block.
    property "no string, integer or boolean encodes to a value with CR, LF or NUL" do
      hostile =
        StreamData.one_of([
          StreamData.member_of(["\r", "\n", "\0", "\r\n", "\u2028", "é", "世", "\u{1F600}"]),
          StreamData.string(:utf8, max_length: 4),
          StreamData.string(Enum.to_list(0..0x7F), max_length: 4)
        ])

      generator =
        StreamData.one_of([
          hostile |> StreamData.list_of() |> StreamData.map(&Enum.join/1),
          StreamData.string(:utf8),
          StreamData.integer(),
          StreamData.map(StreamData.integer(), &(&1 * 1_000_000_000_000_000_000_000)),
          StreamData.boolean()
        ])

      check all(value <- generator) do
        encoded = Headers.encode_value(value)
        refute String.contains?(encoded, ["\r", "\n", "\0"])
        assert header_safe?(encoded)
      end
    end
  end

  describe "encode_value/1" do
    test "matches the spec examples" do
      assert Headers.encode_value("us-west1") == "us-west1"
      assert Headers.encode_value("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?="
      assert Headers.encode_value(" padded ") == "=?base64?IHBhZGRlZCA=?="
      assert Headers.encode_value("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?="

      assert Headers.encode_value("=?base64?literal?=") ==
               "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
    end

    test "encodes leading or trailing whitespace, tabs, DEL and NUL" do
      for value <- [" lead", "trail ", "\tlead", "trail\t", "in\tside", "del\x7F", "nul\0"] do
        encoded = Headers.encode_value(value)
        assert sentinel?(encoded), "expected #{inspect(value)} to be encoded"
        assert Headers.decode_value(encoded) == {:ok, value}
      end
    end

    test "keeps interior spaces and punctuation plain" do
      assert Headers.encode_value("Seattle, WA") == "Seattle, WA"

      assert Headers.encode_value("file:///projects/myapp/config.json") ==
               "file:///projects/myapp/config.json"
    end

    test "encodes values shaped like any =?...?= marker" do
      assert sentinel?(Headers.encode_value("=?utf-8?q?x?="))
      assert sentinel?(Headers.encode_value("=?="))
    end

    test "encodes integers and booleans" do
      assert Headers.encode_value(42) == "42"
      assert Headers.encode_value(-7) == "-7"
      assert Headers.encode_value(0) == "0"
      assert Headers.encode_value(true) == "true"
      assert Headers.encode_value(false) == "false"
    end
  end

  describe "decode_value/1" do
    test "returns plain values unchanged" do
      assert Headers.decode_value("us-west1") == {:ok, "us-west1"}
      assert Headers.decode_value("") == {:ok, ""}
      assert Headers.decode_value("=?base64?no-suffix") == {:ok, "=?base64?no-suffix"}
      assert Headers.decode_value("=?BASE64?SGk=?=") == {:ok, "=?BASE64?SGk=?="}
    end

    test "decodes the spec example" do
      assert Headers.decode_value("=?base64?SGVsbG8sIOS4lueVjA==?=") == {:ok, "Hello, 世界"}
      assert Headers.decode_value("=?base64??=") == {:ok, ""}
    end

    test "rejects malformed sentinels" do
      # invalid alphabet, missing padding, URL-safe alphabet, embedded whitespace
      for value <- [
            "=?base64?!!!!?=",
            "=?base64?SGk?=",
            "=?base64?-_8=?=",
            "=?base64?SG k=?=",
            "=?base64?="
          ] do
        assert Headers.decode_value(value) == :error, "expected :error for #{inspect(value)}"
      end
    end

    test "rejects sentinels whose payload is not UTF-8" do
      assert Headers.decode_value("=?base64?" <> Base.encode64(<<0xFF, 0xFE>>) <> "?=") ==
               :error
    end
  end

  describe "method_header/1 and name_header/2" do
    test "method header is lowercase name with the method as value" do
      assert Headers.method_header("tools/call") == {"mcp-method", "tools/call"}
    end

    test "name header for the three name-carrying methods" do
      assert Headers.name_header("tools/call", %{"name" => "get_weather"}) ==
               {"mcp-name", "get_weather"}

      assert Headers.name_header("prompts/get", %{"name" => "greet"}) == {"mcp-name", "greet"}

      assert Headers.name_header("resources/read", %{"uri" => "file:///a.json"}) ==
               {"mcp-name", "file:///a.json"}
    end

    test "name header uses the resource uri, not a name, for resources/read" do
      assert Headers.name_header("resources/read", %{"name" => "x"}) == nil
    end

    test "name header value is encoded" do
      assert Headers.name_header("tools/call", %{"name" => "天気"}) ==
               {"mcp-name", Headers.encode_value("天気")}

      assert {"mcp-name", "=?base64?" <> _} = Headers.name_header("tools/call", %{"name" => "天気"})
    end

    test "no name header for other methods or non-string params" do
      assert Headers.name_header("tools/list", %{"name" => "x"}) == nil
      assert Headers.name_header("initialize", %{}) == nil
      assert Headers.name_header("tools/call", %{}) == nil
      assert Headers.name_header("tools/call", %{"name" => 1}) == nil
      assert Headers.name_header("tools/call", %{"name" => nil}) == nil
    end

    test "name_header_required?/1" do
      assert Headers.name_header_required?("tools/call")
      assert Headers.name_header_required?("prompts/get")
      assert Headers.name_header_required?("resources/read")
      refute Headers.name_header_required?("tools/list")
      refute Headers.name_header_required?("Tools/Call")
    end

    test "the tasks extension's methods mirror params.taskId" do
      for method <- ["tasks/get", "tasks/update", "tasks/cancel"] do
        assert Headers.name_header_required?(method)
        assert Headers.name_param(method) == "taskId"
        assert Headers.name_header(method, %{"taskId" => "abc_-1"}) == {"mcp-name", "abc_-1"}
      end
    end
  end

  @nested_schema %{
    "type" => "object",
    "properties" => %{
      "region" => %{"type" => "string", "x-mcp-header" => "Region"},
      "query" => %{"type" => "string"},
      "options" => %{
        "type" => "object",
        "properties" => %{
          "shard" => %{"type" => "integer", "x-mcp-header" => "Shard-Id"},
          "dry_run" => %{"type" => "boolean", "x-mcp-header" => "Dry-Run"}
        }
      },
      "list" => %{
        "type" => "array",
        "items" => %{"type" => "string", "x-mcp-header" => "Hidden"}
      }
    }
  }

  describe "header_params/1" do
    test "lists annotations reachable through properties, with paths" do
      params = Headers.header_params(@nested_schema)

      assert Enum.sort_by(params, & &1.path) == [
               %{header: "Dry-Run", path: ["options", "dry_run"], type: "boolean"},
               %{header: "Shard-Id", path: ["options", "shard"], type: "integer"},
               %{header: "Region", path: ["region"], type: "string"}
             ]
    end

    test "ignores annotations under items" do
      refute Enum.any?(Headers.header_params(@nested_schema), &(&1.header == "Hidden"))
    end

    test "empty for schemas without properties" do
      assert Headers.header_params(%{"type" => "object"}) == []
    end
  end

  describe "param_headers/2" do
    test "builds lowercase headers from nested args for an inputSchema or tool" do
      args = %{
        "region" => "us-west1",
        "query" => "SELECT 1",
        "options" => %{"shard" => 42, "dry_run" => false}
      }

      expected = [
        {"mcp-param-dry-run", "false"},
        {"mcp-param-region", "us-west1"},
        {"mcp-param-shard-id", "42"}
      ]

      assert Enum.sort(Headers.param_headers(@nested_schema, args)) == expected

      tool = %{"name" => "execute_sql", "inputSchema" => @nested_schema}
      assert Enum.sort(Headers.param_headers(tool, args)) == expected
    end

    test "omits absent and nil values" do
      assert Headers.param_headers(@nested_schema, %{"region" => nil}) == []
      assert Headers.param_headers(@nested_schema, %{"options" => nil}) == []
      assert Headers.param_headers(@nested_schema, %{"options" => %{}}) == []
    end

    test "integral floats encode as integers; other types are skipped" do
      assert Headers.param_headers(@nested_schema, %{"options" => %{"shard" => 42.0}}) ==
               [{"mcp-param-shard-id", "42"}]

      assert Headers.param_headers(@nested_schema, %{"options" => %{"shard" => 4.5}}) == []
      assert Headers.param_headers(@nested_schema, %{"region" => ["a"]}) == []
      assert Headers.param_headers(@nested_schema, %{"region" => %{"a" => 1}}) == []
      assert Headers.param_headers(@nested_schema, %{"options" => "not a map"}) == []
    end

    test "encodes unsafe values" do
      assert Headers.param_headers(@nested_schema, %{"region" => "Hello, 世界"}) ==
               [{"mcp-param-region", "=?base64?SGVsbG8sIOS4lueVjA==?="}]
    end
  end

  defp schema_with(properties), do: %{"type" => "object", "properties" => properties}

  describe "validate_x_mcp_header/1" do
    test "accepts valid annotations, including nested properties" do
      assert Headers.validate_x_mcp_header(
               Map.update!(@nested_schema, "properties", &Map.delete(&1, "list"))
             ) ==
               :ok

      assert Headers.validate_x_mcp_header(%{"type" => "object"}) == :ok
    end

    test "accepts a property literally named \"properties\"" do
      schema =
        schema_with(%{"properties" => %{"type" => "string", "x-mcp-header" => "Props"}})

      assert Headers.validate_x_mcp_header(schema) == :ok
      assert [%{header: "Props", path: ["properties"]}] = Headers.header_params(schema)
    end

    test "rejects annotations inside items" do
      assert {:error, [message]} = Headers.validate_x_mcp_header(@nested_schema)
      assert message =~ "Hidden"
      assert message =~ "items"
      assert message =~ "reachable"
    end

    test "rejects annotations inside oneOf, $defs, additionalProperties and the root" do
      cases = [
        %{"oneOf" => [schema_with(%{"a" => %{"type" => "string", "x-mcp-header" => "A"}})]},
        %{"$defs" => %{"d" => %{"type" => "string", "x-mcp-header" => "A"}}},
        %{"additionalProperties" => %{"type" => "string", "x-mcp-header" => "A"}},
        %{
          "type" => "object",
          "properties" => %{
            "a" => %{"anyOf" => [%{"type" => "string", "x-mcp-header" => "A"}]}
          }
        },
        %{"type" => "string", "x-mcp-header" => "A"}
      ]

      for schema <- cases do
        assert {:error, [message]} = Headers.validate_x_mcp_header(schema)
        assert message =~ "\"A\""
        assert message =~ "reachable"
      end
    end

    test "rejects number and other non-primitive types" do
      for type <- ["number", "object", "array", nil, ["string", "null"]] do
        property =
          if type, do: %{"type" => type, "x-mcp-header" => "N"}, else: %{"x-mcp-header" => "N"}

        assert {:error, [message]} =
                 Headers.validate_x_mcp_header(schema_with(%{"n" => property}))

        assert message =~ "\"N\""
        assert message =~ "type"
      end
    end

    test "rejects case-insensitive duplicates" do
      schema =
        schema_with(%{
          "a" => %{"type" => "string", "x-mcp-header" => "Region"},
          "b" => %{
            "type" => "object",
            "properties" => %{"c" => %{"type" => "string", "x-mcp-header" => "region"}}
          }
        })

      assert {:error, [message]} = Headers.validate_x_mcp_header(schema)
      assert message =~ "duplicate"
      assert message =~ "\"Region\""
      assert message =~ "\"region\""
    end

    test "rejects invalid tokens" do
      for name <- ["Bad Name", "a:b", "a/b", "é", "a\"b", "(x)"] do
        schema = schema_with(%{"p" => %{"type" => "string", "x-mcp-header" => name}})
        assert {:error, [message]} = Headers.validate_x_mcp_header(schema)
        assert message =~ "token", "expected token error for #{inspect(name)}"
      end
    end

    test "accepts every tchar" do
      name = "!#$%&'*+-.^_`|~09azAZ"

      assert Headers.validate_x_mcp_header(
               schema_with(%{"p" => %{"type" => "string", "x-mcp-header" => name}})
             ) ==
               :ok
    end

    test "rejects empty, non-string and CR/LF names" do
      for {name, fragment} <- [
            {"", "empty"},
            {1, "string"},
            {"a\r\nb", "CR or LF"},
            {"a\n", "CR or LF"}
          ] do
        schema = schema_with(%{"p" => %{"type" => "string", "x-mcp-header" => name}})
        assert {:error, [message]} = Headers.validate_x_mcp_header(schema)
        assert message =~ fragment
        refute message =~ "\r"
        refute message =~ "\n"
      end
    end

    test "error messages carry the JSON pointer of the offending annotation" do
      schema = schema_with(%{"a/b" => %{"type" => "number", "x-mcp-header" => "X"}})
      assert {:error, [message]} = Headers.validate_x_mcp_header(schema)
      assert message =~ "#/properties/a~1b"
    end

    test "reports every problem" do
      schema =
        schema_with(%{
          "a" => %{"type" => "number", "x-mcp-header" => "Bad Name"},
          "b" => %{"type" => "array", "items" => %{"type" => "string", "x-mcp-header" => "I"}}
        })

      assert {:error, errors} = Headers.validate_x_mcp_header(schema)
      assert length(errors) == 3
    end
  end

  describe "value_matches?/2" do
    test "strings compare exactly and case-sensitively" do
      assert Headers.value_matches?("us-west1", "us-west1")
      refute Headers.value_matches?("US-WEST1", "us-west1")
      refute Headers.value_matches?("42", "042")
    end

    test "integers compare numerically, including integral floats" do
      assert Headers.value_matches?("42", 42)
      assert Headers.value_matches?("42", 42.0)
      assert Headers.value_matches?("-7", -7)
      assert Headers.value_matches?("0", 0)
      assert Headers.value_matches?("0", 0.0)
      refute Headers.value_matches?("42", 42.5)
      refute Headers.value_matches?("43", 42)
    end

    test "rejects non-canonical integer headers" do
      for header <- ["042", "+42", "42.0", " 42", "42 ", "4e1", "", "-", "0x2A", "٤٢"] do
        refute Headers.value_matches?(header, 42), "expected #{inspect(header)} not to match"
        refute Headers.value_matches?(header, 42.0), "expected #{inspect(header)} not to match"
      end

      refute Headers.value_matches?("-0", 0)
      refute Headers.value_matches?("00", 0)
    end

    test "rejects integers outside the JS-safe range" do
      assert Headers.value_matches?(Integer.to_string(@max_safe), @max_safe)
      assert Headers.value_matches?(Integer.to_string(-@max_safe), -@max_safe)
      refute Headers.value_matches?(Integer.to_string(@max_safe + 1), @max_safe + 1)
      refute Headers.value_matches?(Integer.to_string(-@max_safe - 1), -@max_safe - 1)

      refute Headers.value_matches?(
               String.duplicate("9", 40),
               String.to_integer(String.duplicate("9", 40))
             )
    end

    test "booleans compare against lowercase literals" do
      assert Headers.value_matches?("true", true)
      assert Headers.value_matches?("false", false)
      refute Headers.value_matches?("True", true)
      refute Headers.value_matches?("true", false)
      refute Headers.value_matches?("1", true)
    end

    test "nil and other types never match" do
      refute Headers.value_matches?("", nil)
      refute Headers.value_matches?("null", nil)
      refute Headers.value_matches?("[]", [])
      refute Headers.value_matches?("a", %{})
      refute Headers.value_matches?("true", "TRUE")
    end
  end
end
