defmodule DpExchange.Webull.OrderBookTest do
  @moduledoc """
  Depth, which arrived with the equity surface.

  **This venue's book is equities-only.** The crypto snapshot publishes a top of book and
  nothing beneath it, and the vendor states `US_OPTION` is not supported on the depth
  endpoint. So the category is checked before the request rather than after the refusal.

  The assertion that costs the most to get wrong is the **timestamp**: a depth snapshot
  wearing the local clock cannot be told apart from a current one.
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

  defp depth_row(overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => "F",
        "instrument_id" => "913255275",
        "quote_time" => 1_787_936_147_000,
        "bids" => [
          %{
            "price" => "13.90",
            "size" => "5",
            "order" => [%{"mpid" => "NSDQ", "size" => "3"}, %{"mpid" => "ARCA", "size" => "2"}]
          },
          %{"price" => "13.89", "size" => "12", "order" => []}
        ],
        "asks" => [
          %{"price" => "13.91", "size" => "3", "order" => [%{"mpid" => "NSDQ", "size" => "3"}]},
          %{"price" => "13.92", "size" => "20", "order" => []}
        ]
      },
      overrides
    )
  end

  describe "the book itself" do
    test "both sides come back as price/size levels" do
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.symbol == "F"
      assert length(book.bids) == 2
      assert length(book.asks) == 2

      [{best_bid, best_bid_size} | _rest] = book.bids
      assert Decimal.equal?(best_bid, Decimal.new("13.90"))
      assert Decimal.equal?(best_bid_size, Decimal.new("5"))
      assert book.provider == :webull
    end

    test "the level's own size is used, not a sum over its participants" do
      # The venue reports 5 at the level and 3+2 across participants. They agree here and
      # will not always: attribution can be partial, and the level size is the number the
      # venue stands behind.
      row =
        depth_row(%{
          "bids" => [
            %{
              "price" => "13.90",
              "size" => "5",
              "order" => [%{"mpid" => "NSDQ", "size" => "1"}]
            }
          ]
        })

      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert [{_price, size}] = book.bids
      assert Decimal.equal?(size, Decimal.new("5"))
      refute Decimal.equal?(size, Decimal.new("1"))
    end

    test "the venue's quote_time is the book's time" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.timestamp == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end

    test "an undated book is REFUSED, not stamped with the local clock" do
      row = depth_row() |> Map.delete("quote_time")

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )
    end

    test "the sequence is nil, because this endpoint publishes none" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row()]),
                 retry_attempts: 0
               )

      assert book.sequence == nil
    end

    test "an empty side is an empty list" do
      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([depth_row(%{"asks" => []})]),
                 retry_attempts: 0
               )

      assert book.asks == []
      assert book.bids != []
    end

    test "a level with no price is dropped rather than carried as nil" do
      # A level without a price is not a level. Keeping it would put a `{nil, size}` tuple
      # into a book that a caller will fold over.
      row = depth_row(%{"bids" => [%{"size" => "5"}, %{"price" => "13.89", "size" => "12"}]})

      assert {:ok, book} =
               Rest.get_order_book("F", @credentials,
                 plug: responding([row]),
                 retry_attempts: 0
               )

      assert [{price, _size}] = book.bids
      assert Decimal.equal?(price, Decimal.new("13.89"))
    end

    test "an empty response is unreadable, not an empty book" do
      # No row means the venue said nothing about this symbol. An empty book would claim it
      # said there is no depth.
      assert {:error, _reason} =
               Rest.get_order_book("F", @credentials, plug: responding([]), retry_attempts: 0)
    end
  end

  describe "the category the venue restricts" do
    test "US_STOCK is the default and US_ETF is accepted" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "category=US_STOCK"

      assert {:ok, _etf} =
               Rest.get_order_book("SPY", @credentials,
                 category: "US_ETF",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, etf_query}
      assert etf_query =~ "category=US_ETF"
    end

    test "US_OPTION is refused before the request, as the vendor states" do
      exploding = fn _conn -> raise "must not ask this endpoint for option depth" end

      assert {:error, {:unsupported_book_category, "US_OPTION"}} =
               Rest.get_order_book("AAPL", @credentials,
                 category: "US_OPTION",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a crypto category is refused — this venue publishes no crypto depth" do
      exploding = fn _conn -> raise "must not ask this endpoint for crypto depth" end

      assert {:error, {:unsupported_book_category, "US_CRYPTO"}} =
               Rest.get_order_book("BTCUSD", @credentials,
                 category: "US_CRYPTO",
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "the parameters the venue requires" do
    test "depth defaults to the venue's L2 level count and can be set" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "depth=10"

      assert {:ok, _l1} =
               Rest.get_order_book("F", @credentials, depth: 1, plug: plug, retry_attempts: 0)

      assert_receive {:query, l1_query}
      assert l1_query =~ "depth=1"
    end

    test "overnight_required is always sent, because the venue marks it required" do
      # An omitted required parameter is a refusal the caller cannot read.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([depth_row()]))
      end

      assert {:ok, _book} = Rest.get_order_book("F", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "overnight_required=false"

      assert {:ok, _overnight} =
               Rest.get_order_book("F", @credentials,
                 overnight: true,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, overnight_query}
      assert overnight_query =~ "overnight_required=true"
    end
  end

  describe "the tape — five side codes and two known ones" do
    defp tick_body(overrides \\ %{}) do
      [
        %{
          "symbol" => "AAPL",
          "instrument_id" => "913256409",
          "result" => [
            Map.merge(
              %{"time" => 1_761_182_953_043, "price" => "48.07", "volume" => "1", "side" => "B"},
              overrides
            )
          ]
        }
      ]
    end

    test "a tick comes back as a Trade" do
      assert {:ok, [%Types.Trade{} = t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      assert t.symbol == "AAPL"
      assert Decimal.equal?(t.price, Decimal.new("48.07"))
      assert Decimal.equal?(t.quantity, Decimal.new("1"))
      assert t.side == :buy
      assert t.provider == :webull
    end

    test "B and S map; G, L and N do NOT" do
      # The venue documents the field as "Such as: B S G L N" and defines none of them. B
      # and S are unambiguous; the other three are documented nowhere the vendor publishes.
      # Folding them into buy or sell would put volume on the wrong side of a delta, which
      # is the number a caller reads a tape for.
      for {code, expected} <- [{"B", :buy}, {"S", :sell}, {"G", nil}, {"L", nil}, {"N", nil}] do
        assert {:ok, [t]} =
                 Rest.get_trades("AAPL", @credentials,
                   plug: responding(tick_body(%{"side" => code})),
                   retry_attempts: 0
                 )

        assert t.side == expected, "side #{code} mapped to #{inspect(t.side)}"
      end
    end

    test "there is no per-tick id on this endpoint, and nil says so" do
      assert {:ok, [t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      assert t.id == nil
    end

    test "broken is false — this venue publishes no bust flag here" do
      assert {:ok, [t]} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body()),
                 retry_attempts: 0
               )

      refute t.broken
    end

    test "an undated tick is refused, never stamped with the local clock" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades("AAPL", @credentials,
                 plug: responding(tick_body(%{"time" => nil})),
                 retry_attempts: 0
               )
    end

    test "the session is always sent, and defaults to regular hours" do
      # The venue marks trading_sessions required. RTH is the default because it is the
      # session the rest of this package's price data comes from.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tick_body()))
      end

      assert {:ok, [_t]} = Rest.get_trades("AAPL", @credentials, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "trading_sessions=RTH"
      assert query =~ "count=30"

      assert {:ok, [_multi]} =
               Rest.get_trades("AAPL", @credentials,
                 sessions: ["PRE", "RTH"],
                 limit: 500,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, multi}
      assert multi =~ "trading_sessions=PRE%2CRTH"
      assert multi =~ "count=500"
    end

    test "US_OPTION is refused, as it is on the depth endpoint" do
      exploding = fn _conn -> raise "must not ask the tick endpoint for options" end

      assert {:error, {:unsupported_book_category, "US_OPTION"}} =
               Rest.get_trades("AAPL", @credentials,
                 category: "US_OPTION",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an empty tape is an empty list" do
      body = [%{"symbol" => "AAPL", "result" => []}]

      assert {:ok, []} =
               Rest.get_trades("AAPL", @credentials, plug: responding(body), retry_attempts: 0)
    end
  end
end
