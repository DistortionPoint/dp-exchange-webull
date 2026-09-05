defmodule DpExchange.Webull.OrderMappingTest do
  @moduledoc """
  What a caller is handed when the venue sends a word this package does not know.

  Every one of these assertions is that the answer is `nil`. The failure this guards is the
  one §0 names: a `SIDEWAYS` becoming `:buy` because `:buy` was the nearest atom to hand
  stays plausible all the way to whatever reads it.

  It also covers the refusal branches, because a venue that answers `400` with a message is
  saying something different from a venue that times out, and a caller retrying the first is
  retrying something that will refuse again.
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
  @account "93IUJ28O9VO2KBGHDHR4H9"

  defp row(overrides) do
    Map.merge(
      %{
        "client_order_id" => "abc",
        "symbol" => "BTCUSD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "GTC",
        "order_status" => "WORKING",
        "qty" => "0.5"
      },
      overrides
    )
  end

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp fetch(overrides) do
    {:ok, order} =
      Rest.get_order(@credentials, "abc",
        plug: responding([row(overrides)]),
        account_id: @account,
        retry_attempts: 0
      )

    order
  end

  describe "the venue's vocabulary, and everything outside it" do
    for {venue, expected} <- [{"BUY", :buy}, {"SELL", :sell}] do
      test "side #{venue} is #{expected}" do
        assert fetch(%{"side" => unquote(venue)}).side == unquote(expected)
      end
    end

    test "a side this package does not know is nil" do
      assert fetch(%{"side" => "SIDEWAYS"}).side == nil
    end

    # W1: all five order types this package's own `@order_type_names` forward-encodes,
    # and that `capabilities/0` declares supported, must decode back. Before the fix,
    # `STOP_LOSS` and `TRAILING_STOP_LOSS` silently answered `nil` here despite being
    # genuinely real values this package itself sends on `place_order/3`.
    for {venue, expected} <- [
          {"MARKET", :market},
          {"LIMIT", :limit},
          {"STOP_LOSS", :stop},
          {"STOP_LOSS_LIMIT", :stop_limit},
          {"TRAILING_STOP_LOSS", :trailing_stop}
        ] do
      test "order type #{venue} is #{expected}" do
        assert fetch(%{"order_type" => unquote(venue)}).order_type == unquote(expected)
      end
    end

    test "an order type this package does not know is nil" do
      # "TRAILING_STOP" (no _LOSS) is not a real Webull value — the real one is
      # TRAILING_STOP_LOSS, covered above. This exercises the genuine unknown-value path.
      assert fetch(%{"order_type" => "TRAILING_STOP"}).order_type == nil
    end

    test "a missing order type is nil rather than a default" do
      assert fetch(%{"order_type" => nil}).order_type == nil
    end

    # W1: all five TIFs this package's own `@tif_names` forward-encodes, and that
    # `capabilities/0` declares supported, must decode back. Before the fix, `GTD` and
    # `FOK` silently answered `nil` here.
    for {venue, expected} <- [
          {"IOC", :ioc},
          {"DAY", :day},
          {"GTC", :gtc},
          {"GTD", :gtd},
          {"FOK", :fok}
        ] do
      test "time in force #{venue} is #{expected}" do
        assert fetch(%{"time_in_force" => unquote(venue)}).time_in_force == unquote(expected)
      end
    end

    test "a time in force this package does not know is nil" do
      # "GFD" is a real Robinhood value, not one Webull publishes — genuine unknown-value
      # path, not one of the five this package encodes.
      assert fetch(%{"time_in_force" => "GFD"}).time_in_force == nil
    end

    for {venue, expected} <- [
          {"PENDING", :pending},
          {"WORKING", :open},
          {"PARTIAL_FILLED", :open},
          {"FILLED", :filled},
          {"CANCELLED", :cancelled},
          {"CANCELED", :cancelled},
          {"REJECTED", :rejected},
          {"EXPIRED", :expired}
        ] do
      test "status #{venue} is #{expected}" do
        assert fetch(%{"order_status" => unquote(venue)}).status == unquote(expected)
      end
    end

    test "a missing symbol leaves the symbol nil rather than crashing" do
      assert fetch(%{"symbol" => nil}).symbol == nil
    end
  end

  describe "what the venue said when it said no" do
    test "a 400 carrying a message keeps the message" do
      assert {:refused, {:venue_error, "insufficient buying power"}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"msg" => "insufficient buying power"}, 400),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a 403 carrying only a code keeps the code" do
      assert {:refused, {:venue_error, "TRADE_NOT_PERMITTED"}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"code" => "TRADE_NOT_PERMITTED"}, 403),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a refusal that explains nothing is still a refusal, not an error" do
      assert {:refused, :refused} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding([], 401),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a 500 is an error, because nobody refused anything" do
      assert {:error, {:exchange_error, :webull, message}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"msg" => "boom"}, 500),
                 account_id: @account,
                 retry_attempts: 0
               )

      # The HTTP layer classifies 5xx before this module sees it; either way it is an error
      # and carries the status.
      assert message =~ "500"
    end

    test "a body that is not JSON at all does not crash the refusal reader" do
      plug = fn conn -> Plug.Conn.resp(conn, 400, "<html>gateway</html>") end

      assert {:refused, :refused} =
               Rest.cancel_order(@credentials, "abc",
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )
    end
  end

  describe "reading an order the venue did not send" do
    test "an empty list is an unreadable response, not a missing order" do
      # `[]` here means "the venue answered about no orders". Returning `{:ok, nil}` would
      # make a caller's `nil` check the only thing between that and a phantom order.
      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([]),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "get_order without an account is refused before the call" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, :account_id_required} =
               Rest.get_order(@credentials, "abc", plug: exploding, retry_attempts: 0)
    end

    test "get_orders without an account is refused before the call" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, :account_id_required} =
               Rest.get_orders(@credentials, plug: exploding, retry_attempts: 0)
    end

    test "a limit is sent to the venue as its page size" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 limit: 25,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "page_size=25"
    end
  end
end
