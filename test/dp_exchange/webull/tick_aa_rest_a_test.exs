defmodule DpExchange.Webull.TickAaRestATest do
  @moduledoc """
  Branches of `DpExchange.Webull.Rest` that the rest of the suite never reached: the refusals
  and shape failures that exist so a venue's odd answer is reported, never substituted.

  Each test drives the public function that reaches the branch and asserts what the branch
  MUST do - fail closed, carry the venue's own words, or keep a value as sent.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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

  # Refuses every request the way a full bucket does.
  defmodule FullLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 5_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "test-key", app_secret: "test-secret-not-real"}
  @account "ACCT-TEST-1"

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp raw(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end
  end

  defp fixture!(name) do
    [__DIR__, "..", "..", "fixtures", "spec_examples", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  describe "get_prices/3 halving a chunk the venue rejects for its content" do
    # `BADUSD` makes the venue refuse any request that names it with `status`; every other
    # request is answered row by row.
    defp rejecting_bad_symbol(status, body) do
      fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        natives = String.split(conn.query_params["symbols"], ",")

        if "BADUSD" in natives do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(status, body)
        else
          Req.Test.json(conn, for(n <- natives, do: %{"symbol" => n, "price" => "3"}))
        end
      end
    end

    test "a 400 that carries the venue's words is halved, and only the bad symbol keeps them" do
      plug = rejecting_bad_symbol(400, ~s({"message":"unknown symbol"}))

      assert {:ok, results} =
               Rest.get_prices(["ETH-USD", "BAD-USD"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert {:ok, %Types.Quote{}} = results["ETH-USD"]
      assert {:refused, {:venue_error, 400, "unknown symbol"}} = results["BAD-USD"]
    end

    test "a 400 with no readable reason is halved the same way and keeps the bare status" do
      plug = rejecting_bad_symbol(400, "{}")

      assert {:ok, results} =
               Rest.get_prices(["ETH-USD", "BAD-USD"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert {:ok, %Types.Quote{}} = results["ETH-USD"]
      assert {:refused, {:venue_error, 400}} = results["BAD-USD"]
    end
  end

  describe "option bars" do
    defp aligned_option_bars do
      "bars_option.json"
      |> fixture!()
      |> Jason.encode!()
      |> String.replace("2021-12-28T09:00:09.945+0000", "2021-12-28T09:00:00.000+0000")
      |> Jason.decode!()
    end

    test "a range whose bounds are both absent is no range, so it is not refused" do
      assert {:ok, [%Types.Candle{}]} =
               Rest.get_historical_prices(
                 "AAPL260522C00300000",
                 "1m",
                 [start: nil, end: nil],
                 @credentials,
                 category: "US_OPTION",
                 plug: responding(aligned_option_bars()),
                 retry_attempts: 0
               )
    end
  end

  describe "stock bars refuse a reply they cannot read" do
    defp stock_bars(plug) do
      Rest.get_historical_prices("AAPL", "1d", [], @credentials,
        category: "US_STOCK",
        plug: plug,
        retry_attempts: 0
      )
    end

    test "an object with no result list is an unexpected shape, not an empty series" do
      assert {:error, :unexpected_response_shape} = stock_bars(responding(%{"foo" => 1}))
    end

    test "a group whose result is not a list refuses the whole reply" do
      assert {:error, :unexpected_response_shape} =
               stock_bars(responding([%{"symbol" => "AAPL", "result" => "not-a-list"}]))
    end
  end

  describe "pagination keys" do
    defp group(client_order_id) do
      %{
        "combo_type" => "NORMAL",
        "orders" => [
          %{
            "client_order_id" => client_order_id,
            "symbol" => "AAPL",
            "side" => "BUY",
            "order_type" => "LIMIT",
            "time_in_force" => "DAY",
            "status" => "PENDING",
            "total_quantity" => "1"
          }
        ]
      }
    end

    defp orders(plug),
      do: Rest.get_orders(@credentials, plug: plug, account_id: @account, retry_attempts: 0)

    test "a cursor that is not text is refused, never sent back or read as the last page" do
      for bad <- [5, ["a"], %{"k" => "v"}] do
        body = %{"data" => [group("c-1")], "pagination_key" => bad}
        assert {:error, :unexpected_pagination_key} = orders(responding(body))
      end
    end

    test "an empty cursor ends the walk" do
      body = %{"data" => [group("c-1")], "pagination_key" => ""}
      assert {:ok, [%{id: "c-1"}]} = orders(responding(body))
    end
  end

  describe "an unexpected status on a write" do
    test "a POST answered with a 4xx the package has no name for keeps the status and body" do
      assert {:error, {:exchange_error, :webull, "HTTP 418: " <> _body}} =
               Rest.check_token("token-test", @credentials,
                 plug: responding(%{"msg" => "teapot"}, 418),
                 retry_attempts: 0
               )
    end
  end

  describe "get_news/2 over the event-stream POST" do
    defp news(plug),
      do: Rest.get_news(@credentials, symbols: ["AAPL"], plug: plug, retry_attempts: 0)

    test "a 400 is a refusal carrying the venue's words" do
      assert {:refused, {:venue_error, 400, "bad lang"}} =
               news(responding(%{"message" => "bad lang"}, 400))
    end

    test "a 404 is a refusal, not an error to retry" do
      assert {:refused, :not_found} = news(responding(%{}, 404))
    end

    test "a status between success and refusal keeps the status and body" do
      assert {:error, {:exchange_error, :webull, "HTTP 418: " <> _body}} =
               news(responding(%{"msg" => "teapot"}, 418))
    end

    test "a server error is an error, not a refusal" do
      assert {:error, {:exchange_error, :webull, message}} =
               news(responding(%{"msg" => "down"}, 500))

      assert message =~ "500"
    end
  end

  describe "get_balances/2" do
    test "a reply that is not an object is an unexpected shape, not an account holding nothing" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@credentials,
                 account_id: @account,
                 plug: responding([]),
                 retry_attempts: 0
               )
    end
  end

  describe "preview_order/3" do
    test "a reply that is neither rows nor an object is an unexpected shape" do
      request = %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        quantity: Decimal.new("10"),
        price: Decimal.new("190"),
        order_type: :limit,
        time_in_force: :day
      }

      assert {:error, :unexpected_response_shape} =
               Rest.preview_order(@credentials, request,
                 account_id: @account,
                 # A `data` that is neither rows nor an object. (A bare JSON string decodes
                 # to text and is refused earlier, as an undecodable body.)
                 plug: raw(~s({"data": 5})),
                 retry_attempts: 0
               )
    end
  end

  describe "replace_order/4" do
    test "the venue refusing the replace itself comes back as the refusal, with its words" do
      assert {:refused, {:venue_error, 400, "order not amendable"}} =
               Rest.replace_order(@credentials, "abc", %{quantity: 3},
                 account_id: @account,
                 instrument_type: :equity,
                 order_type: :limit,
                 plug: responding(%{"message" => "order not amendable"}, 400),
                 retry_attempts: 0
               )
    end
  end

  describe "volume profile sessions" do
    defp footprint(session) do
      [
        %{
          "symbol" => "AAPL",
          "result" => [
            %{
              "time" => 1_787_936_147_000,
              "trading_session" => session,
              "total" => "10",
              "delta" => "2",
              "buy_total" => "6",
              "sell_total" => "4",
              "buy_detail" => %{"24.20" => "6"},
              "sell_detail" => %{"24.20" => "4"}
            }
          ]
        }
      ]
    end

    test "each of the venue's session codes is read as its own session" do
      for {code, expected} <- [
            {"PRE", :pre_market},
            {"ATH", :after_hours},
            {"OVN", :overnight}
          ] do
        assert {:ok, [%Types.VolumeProfile{session: ^expected}]} =
                 Rest.get_volume_profile("AAPL", "5m", @credentials,
                   plug: responding(footprint(code)),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "auction imbalance fields the venue sends oddly" do
    defp imbalance(overrides) do
      [
        Map.merge(
          %{
            "symbol" => "AAPL",
            "paired_shares" => "701859",
            "imbalance_shares" => "5715",
            "imbalance_side" => "2",
            "imbalance_ref_price" => "253.83",
            "imbalance_action_type" => "PRE_CLOSE",
            "imbalance_time" => 1_774_272_599_000
          },
          overrides
        )
      ]
    end

    defp read_imbalance(overrides) do
      Rest.get_auction_imbalance("AAPL", @credentials,
        auction: :closing,
        plug: responding(imbalance(overrides)),
        retry_attempts: 0
      )
    end

    test "a time that is neither an epoch nor ISO 8601 is nil, not an invented instant" do
      assert {:ok, [%Types.AuctionImbalance{venue_time: nil}]} =
               read_imbalance(%{"imbalance_time" => "after the close"})
    end

    test "a side code sent as a number is carried as its text" do
      assert {:ok, [%Types.AuctionImbalance{side: "2"}]} =
               read_imbalance(%{"imbalance_side" => 2})
    end
  end

  describe "get_trades/3 sessions" do
    test "a single session given as text is sent as it stands" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})
        Req.Test.json(conn, [%{"symbol" => "AAPL", "result" => []}])
      end

      assert {:ok, []} =
               Rest.get_trades("AAPL", @credentials,
                 sessions: "PRE",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}, 5_000
      assert query =~ "trading_sessions=PRE"
    end
  end

  describe "oauth_token/3" do
    test "a status the package has no name for keeps the status and body" do
      assert {:error, {:exchange_error, :webull, "HTTP 404: " <> _body}} =
               Rest.oauth_token("CLIENT", "test-secret-not-real",
                 code: "c",
                 plug: responding(%{"msg" => "gone"}, 404),
                 retry_attempts: 0
               )
    end

    test "plain http is accepted for a loopback host alone" do
      assert {:ok, %{"access_token" => "tok-test"}} =
               Rest.oauth_token("CLIENT", "test-secret-not-real",
                 code: "c",
                 oauth_url: "http://localhost",
                 plug: responding(%{"access_token" => "tok-test"}),
                 retry_attempts: 0
               )
    end

    test "the UAT environment exchanges at the sandbox host, never the production one" do
      me = self()

      plug = fn conn ->
        send(me, {:host, conn.host})
        Req.Test.json(conn, %{"access_token" => "tok-test"})
      end

      assert {:ok, _tokens} =
               Rest.oauth_token("CLIENT", "test-secret-not-real",
                 code: "c",
                 environment: :uat,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:host, "oauth-open-api.sandbox.webull.com"}, 5_000
    end
  end

  describe "create_watchlist/4 when the member add is decided before sending" do
    test "the watchlist that now exists is reported with the plain reason, not as unconfirmed" do
      # The create goes out; our own limiter then refuses the add, so nothing was sent for it.
      # The caller learns the watchlist exists and is empty, and that the add never left.
      plug = fn conn ->
        Config.put_override(:rate_limit_module, FullLimiter)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"watchlist_id" => "wl-test-1"}]))
      end

      assert {:error,
              {:watchlist_created_without_members, "wl-test-1",
               {:exchange_error, :webull, "Throttled by our own rate limiter" <> _rest}}} =
               Rest.create_watchlist("Tech", ["AAPL"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "write_outcome/2 bounds what it carries" do
    test "a text reason is cut to 2048 characters" do
      long = String.duplicate("x", 5_000)

      assert {:error, {:write_unconfirmed, nil, bounded}} = Rest.write_outcome({:error, long})
      assert bounded == String.duplicate("x", 2_048)
    end

    test "a reason of any other shape is carried as bounded text" do
      reason = %{detail: String.duplicate("y", 5_000)}

      assert {:error, {:write_unconfirmed, nil, bounded}} = Rest.write_outcome({:error, reason})
      assert bounded == inspect(reason, limit: 50, printable_limit: 2_048)
    end
  end
end
