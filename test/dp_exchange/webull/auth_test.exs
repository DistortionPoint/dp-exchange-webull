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
      empty = Auth.signature(@app_key, @app_secret, @path, @query, "", @host, @timestamp, @nonce)

      hashed_empty =
        Auth.signature(@app_key, @app_secret, @path, @query, " ", @host, @timestamp, @nonce)

      refute empty == hashed_empty
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
  end
end
