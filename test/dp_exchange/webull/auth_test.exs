defmodule DpExchange.Webull.AuthTest do
  use ExUnit.Case, async: true

  alias DpExchange.Webull.Auth

  # The venue's own published worked example. A signature scheme with six
  # ordering-sensitive steps is not something to assume was read correctly, and this is
  # the only assertion that can tell.
  @path "/trade/place_order"
  @query %{"a1" => "webull", "a2" => "123", "a3" => "xxx", "q1" => "yyy"}
  @app_key "776da210ab4a452795d74e726ebd74b6"
  @app_secret "0f50a2e853334a9aae1a783bee120c1f"
  @timestamp "2022-01-04T03:55:31Z"
  @nonce "48ef5afed43d4d91ae514aaeafbc29ba"
  @host "api.webull.com"
  @body ~s({"k1":123,"k2":"this is the api request body","k3":true,"k4":{"foo":[1,2]}})
  @expected "kvlS6opdZDhEBo5jq40nHYXaLvM="

  @credentials %{app_key: @app_key, app_secret: @app_secret}

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        path: @path,
        query_params: @query,
        body: @body,
        host: @host,
        timestamp: @timestamp,
        nonce: @nonce
      },
      overrides
    )
  end

  describe "the venue's worked example" do
    test "reproduces the published signature exactly" do
      assert Auth.signature(
               @app_key,
               @app_secret,
               @path,
               @query,
               @body,
               @host,
               @timestamp,
               @nonce
             ) == @expected
    end

    test "and reaches the headers unchanged" do
      assert {:ok, headers} = Auth.headers(request(), @credentials)

      assert {"x-signature", @expected} in headers
    end
  end

  describe "what the signature covers" do
    test "the HOST is signed, so a signature cannot be replayed elsewhere" do
      # Also why moving between production and UAT changes the signature rather than just
      # the URL.
      other =
        Auth.signature(
          @app_key,
          @app_secret,
          @path,
          @query,
          @body,
          "other.host",
          @timestamp,
          @nonce
        )

      refute other == @expected
    end

    test "the path is signed" do
      other =
        Auth.signature(@app_key, @app_secret, "/other", @query, @body, @host, @timestamp, @nonce)

      refute other == @expected
    end

    test "the body is signed" do
      other =
        Auth.signature(
          @app_key,
          @app_secret,
          @path,
          @query,
          ~s({"k1":124}),
          @host,
          @timestamp,
          @nonce
        )

      refute other == @expected
    end

    test "the nonce is signed, so two identical requests differ" do
      other =
        Auth.signature(@app_key, @app_secret, @path, @query, @body, @host, @timestamp, "other")

      refute other == @expected
    end

    test "an empty body omits the MD5 segment rather than hashing the empty string" do
      # `MD5("")` is a real value — using it would produce a different signed string and a
      # signature the venue rejects, with nothing to say why.
      #
      # The expected values are built here from the six steps, independently of `Auth`, so
      # the test fails if the empty body is ever hashed (comparing against a different body
      # could not tell the two apart).
      empty = Auth.signature("k", "s", "/p", %{}, "", "h", "t", "n")

      str1 =
        "host=h&x-app-key=k&x-signature-algorithm=HMAC-SHA1&x-signature-nonce=n" <>
          "&x-signature-version=1.0&x-timestamp=t"

      sign = fn str3 ->
        :hmac
        |> :crypto.mac(:sha, "s&", URI.encode_www_form(str3))
        |> Base.encode64()
      end

      md5_of_empty = :md5 |> :crypto.hash("") |> Base.encode16(case: :upper)

      assert empty == sign.("/p&" <> str1)
      refute empty == sign.("/p&" <> str1 <> "&" <> md5_of_empty)
    end

    test "query parameter order does not matter, because the inputs are sorted" do
      reordered = %{"q1" => "yyy", "a3" => "xxx", "a1" => "webull", "a2" => "123"}

      assert Auth.signature(
               @app_key,
               @app_secret,
               @path,
               reordered,
               @body,
               @host,
               @timestamp,
               @nonce
             ) == @expected
    end
  end

  describe "headers/2" do
    test "carries the eight fixed headers, plus Content-Type when there is a body" do
      assert {:ok, headers} = Auth.headers(request(), @credentials)
      names = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert names == [
               "Content-Type",
               "host",
               "x-app-key",
               "x-signature",
               "x-signature-algorithm",
               "x-signature-nonce",
               "x-signature-version",
               "x-timestamp",
               "x-version"
             ]

      assert {"Content-Type", "application/json"} in headers
    end

    test "no Content-Type when there is no body — a GET names nothing to declare" do
      # Filed as a live bug: every signed request went out with no declared media type at
      # all, and the venue's streaming-subscribe endpoint (a POST, a real body) answered
      # every one with HTTP 415 "Request media type not support" — DpCryptoManagement's
      # issue #18. A GET's body is "", which is the one case that must stay bare.
      assert {:ok, headers} = Auth.headers(request(%{body: ""}), @credentials)
      names = headers |> Enum.map(&elem(&1, 0))

      refute "Content-Type" in names
    end

    test "x-access-token appears only when the account has one" do
      assert {:ok, without} = Auth.headers(request(), @credentials)
      refute Enum.any?(without, fn {name, _v} -> name == "x-access-token" end)

      assert {:ok, with_token} =
               Auth.headers(request(), Map.put(@credentials, :access_token, "tok"))

      assert {"x-access-token", "tok"} in with_token
    end

    test "an empty access token is treated as absent, not as a credential" do
      assert {:ok, headers} = Auth.headers(request(), Map.put(@credentials, :access_token, ""))

      refute Enum.any?(headers, fn {name, _v} -> name == "x-access-token" end)
    end

    test "partial credentials are refused rather than signed with" do
      # A request signed with an absent secret fails at the venue with an error about
      # signatures, which sends the reader looking in the wrong place.
      assert {:error, {:missing_credentials, :webull}} =
               Auth.headers(request(), %{app_key: @app_key})

      assert {:error, {:missing_credentials, :webull}} = Auth.headers(request(), %{})
    end

    test "the secret never appears in any header value" do
      # This repo is public and headers get pasted into issues.
      assert {:ok, headers} = Auth.headers(request(), @credentials)

      for {_name, value} <- headers do
        refute String.contains?(value, @app_secret)
      end
    end
  end

  describe "nonce/0 and timestamp/1" do
    test "the nonce is 32 hex characters and does not repeat" do
      nonces = for _index <- 1..200, do: Auth.nonce()

      assert Enum.all?(nonces, &(String.length(&1) == 32))
      assert length(Enum.uniq(nonces)) == 200
    end

    test "the timestamp has second precision and a Z suffix" do
      # A fractional second changes the string, and the string is signed.
      assert Auth.timestamp(~U[2022-01-04 03:55:31.123456Z]) == "2022-01-04T03:55:31Z"
    end

    test "an instant in another zone is written in UTC, not with its own offset" do
      # The same instant as the test above, as a clock two hours ahead reads it. It used to
      # come out `2022-01-04T05:55:31+02:00`, which the venue's `Z` form does not accept and
      # which was signed as it stood.
      two_hours_ahead = %DateTime{
        year: 2022,
        month: 1,
        day: 4,
        hour: 5,
        minute: 55,
        second: 31,
        microsecond: {123_456, 6},
        time_zone: "Europe/Test",
        zone_abbr: "TST",
        utc_offset: 7200,
        std_offset: 0
      }

      assert Auth.timestamp(two_hours_ahead) == "2022-01-04T03:55:31Z"
    end
  end

  describe "a blank credential is a missing one, not one to sign with" do
    # `""` satisfies `is_binary/1`, and `is_binary/1` was the whole gate. An empty secret is
    # not a secret — it is the commonest misconfiguration there is, `.env` carrying
    # `NAME=` with nothing after it, which `System.get_env/1` hands back as `""` and not as
    # `nil`. Every module here documents that it refuses to sign a partial credential
    # precisely so the venue's answer does not send the reader to the signing code, which
    # is correct, instead of to the credential, which was never set.
    #
    # Webull's own case: an empty `app_secret` produces the signing key `"&"`, which HMACs
    # as happily as a real one, so nothing local failed.
    @request %{
      path: "/api/quotes",
      query_params: %{},
      body: "",
      host: "api.webull.com",
      timestamp: "2022-01-04T03:55:31Z",
      nonce: "abc123"
    }

    test "an empty or blank app_key or app_secret refuses by name" do
      for credentials <- [
            %{app_key: "k", app_secret: ""},
            %{app_key: "k", app_secret: "   "},
            %{app_key: "", app_secret: "s"},
            %{app_key: "   ", app_secret: "s"}
          ] do
        assert Auth.headers(@request, credentials) ==
                 {:error, {:missing_credentials, :webull}},
               "#{inspect(credentials)} was signed with"
      end
    end

    test "present?/1 agrees with headers/2, which is its entire contract" do
      # It answered `:ok` for a blank pair while `headers/2` went on to sign with it. That
      # is the drift this function exists to prevent: `get_fees/2` has no request to hang
      # the real gate on and uses this instead, and so does the fake.
      for credentials <- [
            %{app_key: "", app_secret: ""},
            %{app_key: "k", app_secret: "  "},
            %{app_key: "  ", app_secret: "s"}
          ] do
        assert Auth.present?(credentials) == {:error, {:missing_credentials, :webull}}
        assert {:error, {:missing_credentials, :webull}} = Auth.headers(@request, credentials)
      end

      assert Auth.present?(%{app_key: "k", app_secret: "s"}) == :ok
      assert {:ok, _headers} = Auth.headers(@request, %{app_key: "k", app_secret: "s"})
    end

    test "a padded or control-character value is invalid, never signed with, never echoed" do
      for credentials <- [
            %{app_key: "k\n", app_secret: "s"},
            %{app_key: "k", app_secret: " s"},
            %{app_key: "k", app_secret: "s\t"},
            %{app_key: "k", app_secret: "s", access_token: "tok\n"},
            %{app_key: "k", app_secret: "s", access_token: " tok"}
          ] do
        expected = {:error, {:invalid_credentials, :webull}}

        assert Auth.present?(credentials) == expected
        assert Auth.headers(@request, credentials) == expected
      end
    end

    test "a non-string app_key or secret is a missing credential" do
      for credentials <- [%{app_key: nil, app_secret: "s"}, %{app_key: "k", app_secret: 5}] do
        assert Auth.present?(credentials) == {:error, {:missing_credentials, :webull}}
        assert Auth.headers(@request, credentials) == {:error, {:missing_credentials, :webull}}
      end
    end
  end
end
