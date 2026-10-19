defmodule DpExchange.Webull.TickAnHttpTest do
  @moduledoc """
  Tick AN, lens J: a write whose answer was lost is never a bare error.

  `oauth_token/3` is a write. An authorization code is single-use and a refresh token may
  rotate, so a transport error, a timeout, a 5xx or a 408, or a 2xx that is no token can all
  follow a grant the venue honoured. It answered a bare `{:error, _}` for each, which a caller
  reads as "worth retrying" and retries with a credential that no longer works. Core's W1 makes
  these `{:error, {:write_unconfirmed, nil, reason}}`, as `create_token/2` already answers.
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

  defp exchange(plug) do
    Rest.oauth_token("CLIENT", "secret", code: "c", plug: plug, retry_attempts: 0)
  end

  describe "oauth_token/3 when the answer may have been lost" do
    test "a transport error or timeout is unconfirmed, with the reason bounded" do
      timing_out = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, {:write_unconfirmed, nil, reason}} = exchange(timing_out)
      assert is_binary(reason) or is_tuple(reason)
      assert inspect(reason) =~ "timeout"
    end

    test "a 5xx is unconfirmed" do
      failing = fn conn -> Plug.Conn.resp(conn, 503, "unavailable") end

      assert {:error, {:write_unconfirmed, nil, _reason}} = exchange(failing)
    end

    test "a 2xx that is not an object is unconfirmed, not a shape error" do
      listing = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "[1, 2]")
      end

      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} = exchange(listing)
    end
  end

  describe "oauth_token/3 when the venue answered" do
    test "a refusal is still a refusal and a grant is still a token" do
      refusing = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"message" => "invalid_grant"}))
      end

      granting = fn conn -> Req.Test.json(conn, %{"access_token" => "tok"}) end

      assert {:refused, {:venue_error, 400, "invalid_grant"}} = exchange(refusing)
      assert {:ok, %{"access_token" => "tok"}} = exchange(granting)
    end
  end
end
