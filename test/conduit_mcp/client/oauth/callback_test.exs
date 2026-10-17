defmodule ConduitMcp.Client.OAuth.CallbackTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.OAuth.{Callback, Error, Pending}
  alias ConduitMcp.Client.Secret

  @issuer "https://as.example"
  @now 1_000

  defp pending(opts \\ []) do
    [
      redirect_uri: "http://127.0.0.1:33418/callback",
      issuer: @issuer,
      resource: "https://mcp.example.com/mcp",
      principal: "user-a",
      now: @now
    ]
    |> Keyword.merge(opts)
    |> Pending.new()
  end

  defp params(pending, extra \\ %{}),
    do: Map.merge(%{"code" => "the-code", "state" => Secret.expose(pending.state)}, extra)

  defp validate(pending, params, opts \\ []),
    do:
      Callback.validate(
        pending,
        params,
        Keyword.merge([principal: "user-a", now: @now + 1], opts)
      )

  test "a valid response returns the code as a Secret" do
    p = pending()
    assert {:ok, code} = validate(p, params(p, %{"iss" => @issuer}))
    assert Secret.expose(code) == "the-code"
  end

  describe "OA-2: state" do
    test "missing, mismatched and non-string state is rejected" do
      p = pending()
      state = Secret.expose(p.state)

      for bad <- [
            nil,
            "",
            "x",
            state <> "x",
            String.slice(state, 0..-2//1),
            String.upcase(state),
            ["#{state}"]
          ] do
        params = if bad, do: params(p, %{"state" => bad}), else: Map.delete(params(p), "state")

        assert {:error, %Error{reason: :invalid_state, data: nil}} = validate(p, params),
               inspect(bad)
      end
    end

    test "a state minted for another flow is rejected" do
      p = pending()
      other = pending()
      assert {:error, %Error{reason: :invalid_state}} = validate(p, params(other))
    end

    test "cross-principal completion is rejected" do
      p = pending()

      assert {:error, %Error{reason: :principal_mismatch}} =
               validate(p, params(p), principal: "user-b")

      assert {:error, %Error{reason: :principal_mismatch}} =
               validate(p, params(p), principal: nil)

      unbound = pending(principal: nil)

      assert {:error, %Error{reason: :principal_mismatch}} =
               validate(unbound, params(unbound), principal: "user-a")

      assert {:ok, _} = validate(unbound, params(unbound), principal: nil)
    end

    test "an expired state is rejected" do
      p = pending()
      assert {:ok, _} = validate(p, params(p), now: @now + 599)
      assert {:error, %Error{reason: :state_expired}} = validate(p, params(p), now: @now + 600)
      assert {:error, %Error{reason: :state_expired}} = validate(p, params(p), now: @now + 86_400)
    end

    test "replay is the host store's job: validate/3 itself is pure" do
      # Documented in Pending and Callback: the host deletes the pending entry
      # on lookup. The same inputs give the same answer here.
      p = pending()
      assert validate(p, params(p)) == validate(p, params(p))
    end
  end

  describe "OA-3: RFC 9207 iss truth table" do
    test "row 1: iss present and equal continues (advertised or not)" do
      for advertised <- [true, false] do
        p = pending(iss_parameter_supported: advertised)
        assert {:ok, _} = validate(p, params(p, %{"iss" => @issuer}))
      end
    end

    test "row 2: iss present and different is rejected (advertised or not)" do
      for advertised <- [true, false] do
        p = pending(iss_parameter_supported: advertised)

        assert {:error, %Error{reason: :iss_mismatch}} =
                 validate(p, params(p, %{"iss" => "https://evil.example"}))
      end
    end

    test "row 3: iss absent while advertised is rejected" do
      p = pending(iss_parameter_supported: true)
      assert {:error, %Error{reason: :iss_missing}} = validate(p, params(p))
      assert {:error, %Error{reason: :iss_missing}} = validate(p, params(p, %{"iss" => nil}))
    end

    test "row 4: iss absent and not advertised continues" do
      p = pending(iss_parameter_supported: false)
      assert {:ok, _} = validate(p, params(p))
    end

    test "no normalization: AS.example vs as.example, trailing slash, default port" do
      p = pending()

      for iss <- [
            "https://AS.example",
            "https://as.example/",
            "https://as.example:443",
            "HTTPS://as.example",
            "",
            ["https://as.example"]
          ] do
        assert {:error, %Error{reason: :iss_mismatch}} = validate(p, params(p, %{"iss" => iss})),
               inspect(iss)
      end
    end

    test "on mismatch, error and error_description are not passed through" do
      p = pending()

      response = %{
        "state" => Secret.expose(p.state),
        "iss" => "https://evil.example",
        "error" => "access_denied",
        "error_description" => "Call +1-555-PHISH to restore access",
        "error_uri" => "https://evil.example/help"
      }

      assert {:error, %Error{reason: :iss_mismatch, data: nil} = error} = validate(p, response)
      refute inspect(error) =~ "PHISH"
      refute Exception.message(error) =~ "PHISH"

      missing = pending(iss_parameter_supported: true)
      response = %{response | "state" => Secret.expose(missing.state)} |> Map.delete("iss")
      assert {:error, %Error{reason: :iss_missing, data: nil}} = validate(missing, response)
    end

    test "the iss check runs before the code is returned" do
      p = pending()

      assert {:error, %Error{reason: :iss_mismatch}} =
               validate(p, params(p, %{"iss" => "https://as.example."}))
    end
  end

  describe "error responses" do
    test "RFC 6749 codes map to typed reasons with the server text in data" do
      p = pending()

      for {code, reason} <- [
            {"access_denied", :access_denied},
            {"invalid_request", :invalid_request},
            {"unauthorized_client", :unauthorized_client},
            {"unsupported_response_type", :unsupported_response_type},
            {"invalid_scope", :invalid_scope},
            {"server_error", :server_error},
            {"temporarily_unavailable", :temporarily_unavailable},
            {"login_required", :authorization_error}
          ] do
        response = %{
          "state" => Secret.expose(p.state),
          "iss" => @issuer,
          "error" => code,
          "error_description" => "why"
        }

        assert {:error,
                %Error{reason: ^reason, data: %{"error" => ^code, "error_description" => "why"}}} =
                 validate(p, response)
      end
    end

    test "an error wins over a code; neither is missing_code" do
      p = pending()

      assert {:error, %Error{reason: :access_denied}} =
               validate(p, params(p, %{"error" => "access_denied"}))

      assert {:error, %Error{reason: :missing_code}} = validate(p, Map.delete(params(p), "code"))
      assert {:error, %Error{reason: :missing_code}} = validate(p, params(p, %{"code" => ""}))
    end

    test "error responses with a bad state surface nothing" do
      p = pending()

      assert {:error, %Error{reason: :invalid_state, data: nil}} =
               validate(p, %{
                 "state" => "forged",
                 "error" => "access_denied",
                 "error_description" => "x"
               })
    end
  end
end
