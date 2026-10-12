defmodule DpExchange.Webull.CleartextDowngradeTest do
  @moduledoc """
  A consumer-overridable URL must not silently downgrade a credential-bearing call to
  cleartext. `:oauth_url` carries the client secret and the code or refresh token in the
  request body; the socket URL carries the App Key in the MQTT CONNECT.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull.{Rest, Socket}

  @moduletag :capture_log

  describe "oauth_token/3 base URL" do
    test "an http:// :oauth_url is refused and nothing is sent" do
      plug = fn _conn -> flunk("no request may be sent over cleartext") end

      for url <- ["http://oauth.example.test", "ftp://x.test", "//no-scheme.test", "garbage"] do
        assert {:error, {:insecure_oauth_url, :https_required}} =
                 Rest.oauth_token("CLIENT", "test-secret-not-real",
                   code: "c",
                   oauth_url: url,
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end

    test "a non-string :oauth_url is refused rather than raising" do
      assert {:error, {:insecure_oauth_url, :https_required}} =
               Rest.oauth_token("CLIENT", "test-secret-not-real",
                 code: "c",
                 oauth_url: :not_a_url,
                 retry_attempts: 0
               )
    end
  end

  describe "Socket.start_link/1 URL" do
    test "a non-loopback ws:// URL is refused before any connection is attempted" do
      for url <- ["ws://data.example.test/mqtt", "http://data.example.test", "not a url"] do
        assert {:error, {:insecure_url, :wss_required}} =
                 Socket.start_link(
                   url: url,
                   subscriber: self(),
                   session_id: "s",
                   app_key: "test-key-not-real"
                 )
      end
    end
  end
end
