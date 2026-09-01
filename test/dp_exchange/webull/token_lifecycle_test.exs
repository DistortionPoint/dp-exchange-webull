defmodule DpExchange.Webull.TokenLifecycleTest do
  @moduledoc """
  The three token endpoints — and the one thing they all guard against.

  **A token that exists is not a token that works.** `create_token/2` returns one that is
  `PENDING` and stays that way until a person enters an SMS code in the Webull app, which is
  not something this package can do. `check_token/3` is the only call that distinguishes
  `PENDING` from `EXPIRED` from `INVALID` — all three fail identically at the next request,
  and each has a different remedy.

  And `oauth_token/3` is **one endpoint doing two jobs on a different host**: `grant_type`
  decides whether it is the host's code exchange or the package's refresh. That is the
  concrete case for why the package/host boundary cannot be read off a URL.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "key", app_secret: "secret"}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.host, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "create_token/2" do
    test "a new token is PENDING and the status is not mapped away" do
      # A caller that treated a successful response as an authenticated session will find
      # every subsequent call refused.
      body = %{
        "token" => "ccb071f764864b65a1fb48484e940a56",
        "expires_at" => 1_755_486_723_000,
        "status" => "PENDING"
      }

      assert {:ok, token} =
               Rest.create_token(@credentials, plug: responding(body), retry_attempts: 0)

      assert token["status"] == "PENDING"
      assert token["expires_at"] == 1_755_486_723_000
    end

    test "it posts to the venue's own path" do
      me = self()

      assert {:ok, _token} =
               Rest.create_token(@credentials,
                 plug: capturing(%{"token" => "t", "status" => "PENDING"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _host, "/auth/tokens/create", _raw}
    end
  end

  describe "check_token/3" do
    test "the token goes in the body and its status comes back unmapped" do
      me = self()

      assert {:ok, checked} =
               Rest.check_token("ccb071f7", @credentials,
                 plug: capturing(%{"token" => "ccb071f7", "status" => "NORMAL"}, me),
                 retry_attempts: 0
               )

      assert checked["status"] == "NORMAL"
      assert_receive {:request, _host, "/auth/tokens/check", raw}
      assert Jason.decode!(raw) == %{"token" => "ccb071f7"}
    end

    for status <- ["PENDING", "NORMAL", "INVALID", "EXPIRED"] do
      test "#{status} survives as the venue's own string" do
        # "Not usable" covers three different problems with three different remedies, so
        # nothing is collapsed into a boolean.
        body = %{"token" => "t", "status" => unquote(status)}

        assert {:ok, checked} =
                 Rest.check_token("t", @credentials, plug: responding(body), retry_attempts: 0)

        assert checked["status"] == unquote(status)
      end
    end
  end

  describe "oauth_token/3 — one endpoint, two operations" do
    test "a code exchanges" do
      me = self()

      assert {:ok, _tokens} =
               Rest.oauth_token("CLIENT", "secret",
                 code: "auth-code",
                 plug: capturing(%{"access_token" => "a"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, host, "/oauth2/tokens/create", raw}
      # A different host from every other endpoint in this package.
      assert host =~ "oauth-open-api"

      form = URI.decode_query(raw)
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "auth-code"
      assert form["client_id"] == "CLIENT"
      assert form["client_secret"] == "secret"
      refute Map.has_key?(form, "refresh_token")
    end

    test "a refresh token refreshes" do
      me = self()

      assert {:ok, _tokens} =
               Rest.oauth_token("CLIENT", "secret",
                 refresh_token: "r-1",
                 plug: capturing(%{"access_token" => "a"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _host, _path, raw}
      form = URI.decode_query(raw)
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "r-1"
      refute Map.has_key?(form, "code")
    end

    test "both together are refused, because the venue would choose and not say" do
      assert {:error, :code_and_refresh_token_are_exclusive} =
               Rest.oauth_token("CLIENT", "secret", code: "c", refresh_token: "r")
    end

    test "neither is refused before a request is made" do
      assert {:error, :code_or_refresh_token_required} =
               Rest.oauth_token("CLIENT", "secret", [])
    end

    test "two expiries come back and they are not the same clock" do
      # A caller tracking only `expires_in` will be surprised when `rt_expires_in` runs out.
      body = %{
        "access_token" => "a",
        "refresh_token" => "r",
        "token_type" => "Bearer",
        "expires_in" => "1800",
        "rt_expires_in" => "1296000"
      }

      assert {:ok, tokens} =
               Rest.oauth_token("CLIENT", "secret",
                 code: "c",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert tokens["expires_in"] == "1800"
      assert tokens["rt_expires_in"] == "1296000"
      refute tokens["expires_in"] == tokens["rt_expires_in"]
    end

    test "a rejected exchange is a refusal, because the same code cannot be retried" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end

      assert {:refused, _body} =
               Rest.oauth_token("CLIENT", "secret", code: "used", plug: plug, retry_attempts: 0)
    end
  end

  describe "the facade" do
    test "all three delegate" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, _token} =
               DpExchange.Webull.create_token(
                 base ++ [plug: responding(%{"token" => "t", "status" => "PENDING"})]
               )

      assert {:ok, _checked} =
               DpExchange.Webull.check_token(
                 "t",
                 base ++ [plug: responding(%{"token" => "t", "status" => "NORMAL"})]
               )

      assert {:ok, _tokens} =
               DpExchange.Webull.oauth_token(
                 "CLIENT",
                 "secret",
                 base ++ [code: "c", plug: responding(%{"access_token" => "a"})]
               )

      assert {:error, :code_or_refresh_token_required} =
               DpExchange.Webull.oauth_token("CLIENT", "secret")
    end
  end
end
