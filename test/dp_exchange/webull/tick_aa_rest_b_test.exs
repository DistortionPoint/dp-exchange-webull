defmodule DpExchange.Webull.TickAaRestBTest do
  @moduledoc """
  Branches of `DpExchange.Webull.Rest` (the write-outcome helpers through the order decoder)
  that no other test reached: refusal wording alternatives, unreadable rows that must be
  refused rather than skipped, and the request-side number renderings.

  Each test asserts what the branch MUST do per the code's own comments: refuse, or carry
  the absence forward, never substitute something plausible.
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

  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp contract(overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => "AAPL250320C00100000",
        "expiration_date" => "2026-03-20",
        "strike_price" => "100",
        "option_type" => "CALL",
        "multiplier" => "100"
      },
      overrides
    )
  end

  defp chain(rows, opts \\ []) do
    Rest.get_option_chain(
      "AAPL",
      @credentials,
      Keyword.merge([plug: responding(rows), retry_attempts: 0], opts)
    )
  end

  describe "write_outcome/2 — what an unproven write carries" do
    test "a reason that is text is bounded to 2 KiB" do
      assert {:error, {:write_unconfirmed, nil, reason}} =
               Rest.write_outcome({:error, String.duplicate("x", 3_000)})

      assert byte_size(reason) == 2_048
    end

    test "a reason of any other shape is carried as its inspected, bounded text" do
      assert {:error, {:write_unconfirmed, nil, "%{a: 1}"}} =
               Rest.write_outcome({:error, %{a: 1}})

      assert {:error, {:write_unconfirmed, nil, "{:a, 1}"}} =
               Rest.write_outcome({:error, {:a, 1}})
    end

    test "a credential refusal is decided before sending, so it is not unconfirmed" do
      assert Rest.unsent?({:invalid_credentials, :webull})

      assert {:error, {:invalid_credentials, :webull}} =
               Rest.write_outcome({:error, {:invalid_credentials, :webull}})
    end
  end

  describe "watchlist writes — a reply that cannot be read" do
    test "a reply with no row at all is unconfirmed, not a success" do
      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Rest.add_watchlist_instruments("wl-1", ["AAPL"], @credentials,
                 plug: responding([]),
                 retry_attempts: 0
               )
    end

    test "a reply whose data is neither rows nor an object is unconfirmed" do
      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Rest.remove_watchlist_instruments("wl-1", ["AAPL"], @credentials,
                 plug: responding(%{"data" => "oops"}),
                 retry_attempts: 0
               )
    end

    # Tick AJ: skipping the entry published a watchlist with a member missing from it.
    test "an instrument entry that is not an object refuses the watchlist read" do
      body = %{
        "watchlist_id" => "wl-1",
        "instruments" => ["junk", %{"symbol" => "AAPL"}]
      }

      assert {:error, :unexpected_response_shape} =
               Rest.get_watchlist("wl-1", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "get_filings/3 — the envelope" do
    test "no envelope at all is no filings" do
      assert {:ok, []} =
               Rest.get_filings("AAPL", @credentials, plug: responding([]), retry_attempts: 0)
    end

    test "more than one envelope is refused rather than read as the first" do
      body = [%{"filings" => []}, %{"filings" => []}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_filings("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "get_news/2 — a reply that is not a news page" do
    test "a body that is not JSON is undecodable, not an empty list of news" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event:message\ndata:{\"type\":\"meta\"}\n\n")
      end

      assert {:error, {:undecodable_response, :webull}} =
               Rest.get_news(@credentials, symbols: ["AAPL"], plug: plug, retry_attempts: 0)
    end

    test "a reply that is a bare object without the data array is not a news page" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: responding(%{"a" => 1}),
                 retry_attempts: 0
               )
    end

    test "a page with no items is an empty list" do
      assert {:ok, []} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: responding(%{"symbol" => "AAPL", "data" => []}),
                 retry_attempts: 0
               )
    end
  end

  describe "paged listings" do
    test "a data field that is not rows is refused, not read as an empty page" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_event_series(@credentials,
                 plug: responding(%{"data" => "oops"}),
                 retry_attempts: 0
               )
    end
  end

  describe "stock bars" do
    test "a group that is not an object refuses the whole reply" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("AAPL", "1m", [], @credentials,
                 category: "US_STOCK",
                 plug: responding(%{"result" => ["junk"]}),
                 retry_attempts: 0
               )
    end
  end

  describe "option contracts" do
    test "a strike given as a number is sent as the venue's exact-strike range" do
      assert {:ok, _chain} =
               chain([contract()], strike: 100, plug: capturing([contract()], self()))

      assert_receive {:request, _path, query}, 5_000
      params = URI.decode_query(query)
      assert params["strike_price_gte"] == "100"
      assert params["strike_price_lte"] == "100"
    end

    test "a row that is not an object is refused, naming it" do
      assert {:error, {:unreadable_option_contract, "junk"}} = chain(["junk"])
    end

    test "an expiry that is not a date is refused, not defaulted" do
      for bad <- ["2026-13-45", 20_260_320] do
        assert {:error, {:unreadable_option_contract, keys}} =
                 chain([contract(%{"expiration_date" => bad})])

        assert "expiration_date" in keys
      end
    end

    test "a strike that is not a number is refused" do
      for bad <- ["abc", [1]] do
        assert {:error, {:unreadable_option_contract, _keys}} =
                 chain([contract(%{"strike_price" => bad})])
      end
    end

    test "a right that is not text is refused" do
      assert {:error, {:unreadable_option_contract, _keys}} =
               chain([contract(%{"option_type" => 1})])
    end

    test "no last trading day is read: the page defines no such field" do
      # `last_trade_date` appears in no page or capture (`option-contract-list.md` lists the
      # contract's fields); a row carrying one is not given a last trading day by it.
      assert {:ok, grid} = chain([contract(%{"last_trade_date" => "2026-03-19"})])

      call = grid.expiries[~D[2026-03-20]][Decimal.new("100")].call
      assert call.last_trading_day == nil
    end
  end

  describe "refusal wording" do
    test "a refusal that carries its words under message keeps them" do
      assert {:refused, {:venue_error, 400, "bad request"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{"message" => "bad request"}, 400),
                 retry_attempts: 0
               )
    end

    test "words under error_description are not read: no page shows that field" do
      assert {:refused, {:venue_error, 401}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{"error_description" => "token expired"}, 401),
                 retry_attempts: 0
               )
    end
  end

  describe "numbers on the wire" do
    test "a Decimal parameter is rendered without an exponent" do
      assert {:ok, _rows} =
               Rest.get_fundamental(
                 :industry_comparisons,
                 "AAPL",
                 @credentials,
                 sort_by: Decimal.new("1E+2"),
                 plug: capturing([], self()),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}, 5_000
      assert URI.decode_query(query)["sort_by"] == "100"
    end

    test "a float parameter is rendered as its digits" do
      assert {:ok, _rows} =
               Rest.get_fundamental(
                 :industry_comparisons,
                 "AAPL",
                 @credentials,
                 sort_by: 1.5,
                 plug: capturing([], self()),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}, 5_000
      assert URI.decode_query(query)["sort_by"] == "1.5"
    end
  end

  describe "place_orders/3 — an unreadable reply" do
    test "a reply whose rows cannot be read carries the ids of the whole batch" do
      order = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("10"),
        price: Decimal.new("180"),
        instrument_type: :equity,
        support_trading_session: :core
      }

      assert {:error, {:order_unconfirmed, [id], :unexpected_response_shape}} =
               Rest.place_orders(@credentials, [order],
                 account_id: "acct-1",
                 plug: responding(%{"data" => "oops"}),
                 retry_attempts: 0
               )

      assert is_binary(id)
    end
  end

  describe "get_orders/2 — a group that cannot be read" do
    test "a group with no legs, a group that is not an object, and a bare object are named" do
      rows = [
        %{"client_order_id" => "c-1", "combo_type" => "NORMAL", "orders" => []},
        "junk",
        %{"nothing" => 1}
      ]

      assert {:error, {:unreadable_orders, ["c-1", nil, nil]}} =
               Rest.get_orders(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0,
                 account_id: "acct"
               )
    end
  end
end
