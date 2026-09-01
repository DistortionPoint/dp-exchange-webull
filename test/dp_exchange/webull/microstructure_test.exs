defmodule DpExchange.Webull.MicrostructureTest do
  @moduledoc """
  Footprints and the auction imbalance — the two equity endpoints with no prior facade.

  The assertions that matter most are about **staleness and about not reconciling numbers
  the venue did not reconcile**. Outside an auction window the venue returns the *last*
  imbalance, so the venue's own time and `observed_at` together are the only way a caller
  tells a live one from this morning's. And a footprint's `delta` is the venue's own figure:
  recomputing it from the totals would paper over a classifier that leaves prints
  unattributed.
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

  describe "footprints" do
    defp footprint_body(overrides \\ %{}) do
      [
        %{
          "symbol" => "AAPL",
          "instrument_id" => "913256135",
          "result" => [
            Map.merge(
              %{
                "time" => 1_787_936_147_000,
                "trading_session" => "RTH",
                "total" => "1000",
                "delta" => "200",
                "buy_total" => "600",
                "sell_total" => "400",
                "buy_detail" => %{"24.20" => "100", "24.21" => "500"},
                "sell_detail" => %{"24.20" => "350", "24.21" => "50"}
              },
              overrides
            )
          ]
        }
      ]
    end

    test "a profile carries the split by price and by side" do
      assert {:ok, [%Types.VolumeProfile{} = profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(footprint_body()),
                 retry_attempts: 0
               )

      assert profile.symbol == "AAPL"
      assert profile.timeframe == "5m"
      assert Decimal.equal?(profile.buy_volume, Decimal.new("600"))
      assert Decimal.equal?(profile.sell_volume, Decimal.new("400"))
      assert profile.session == :regular
      assert profile.provider == :webull
    end

    test "the price maps keep the venue's own price strings" do
      # Two strings that parse to equal decimals are the same level; re-keying would
      # silently merge two of the venue's rows into one.
      assert {:ok, [profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(footprint_body()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(profile.buy_at_price["24.21"], Decimal.new("500"))
      assert Decimal.equal?(profile.sell_at_price["24.20"], Decimal.new("350"))
      assert Types.VolumeProfile.point_of_control(profile) == "24.21"
    end

    test "delta is the venue's figure and is NOT recomputed from the totals" do
      # 600 - 400 is 200, and the venue says 150. A classifier that leaves prints
      # unattributed produces exactly that gap, and it is information rather than a fault.
      assert {:ok, [profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(footprint_body(%{"delta" => "150"})),
                 retry_attempts: 0
               )

      assert Decimal.equal?(profile.delta, Decimal.new("150"))
      refute Decimal.equal?(profile.delta, Decimal.sub(profile.buy_volume, profile.sell_volume))
    end

    test "the five widths this endpoint serves map to the venue's own spans" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(footprint_body()))
      end

      for {canonical, span} <- [
            {"5s", "S5"},
            {"15s", "S15"},
            {"1m", "M1"},
            {"5m", "M5"},
            {"30m", "M30"}
          ] do
        assert {:ok, _profiles} =
                 Rest.get_volume_profile("AAPL", canonical, @credentials,
                   plug: plug,
                   retry_attempts: 0
                 )

        assert_receive {:query, query}
        assert query =~ "timespan=#{span}"
      end
    end

    test "a width this endpoint does not serve is an ERROR, not the nearest one" do
      # The bars endpoint serves more widths than this one. Answering a 1h request with 30m
      # data labelled 1h has every value real and every label wrong.
      exploding = fn _conn -> raise "must not ask footprints for a width they lack" end

      assert {:error, {:unsupported_timeframe, "1h"}} =
               Rest.get_volume_profile("AAPL", "1h", @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the overnight session is refused, as the vendor's own note says" do
      exploding = fn _conn -> raise "must not ask footprints for the OVN session" end

      assert {:error, {:unsupported_session, "OVN"}} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 session: "OVN",
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "completed intervals only — real_time_required is sent as false" do
      # An in-progress footprint has a boundary that has not happened yet, and its split
      # will change before the interval closes.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(footprint_body()))
      end

      assert {:ok, _profiles} =
               Rest.get_volume_profile("AAPL", "5m", @credentials, plug: plug, retry_attempts: 0)

      assert_receive {:query, query}
      assert query =~ "real_time_required=false"
    end

    test "an undated interval is refused rather than placed by the local clock" do
      body = footprint_body() |> put_in([Access.at(0), "result", Access.at(0), "time"], nil)

      assert {:error, :missing_venue_timestamp} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a session the package does not recognise is nil, not the nearest" do
      assert {:ok, [profile]} =
               Rest.get_volume_profile("AAPL", "5m", @credentials,
                 plug: responding(footprint_body(%{"trading_session" => "SOMETHING"})),
                 retry_attempts: 0
               )

      assert profile.session == nil
    end
  end

  describe "the auction imbalance" do
    defp noii_body(overrides \\ %{}) do
      [
        Map.merge(
          %{
            "instrument_id" => "913256135",
            "symbol" => "AAPL",
            "paired_shares" => "701859",
            "imbalance_shares" => "5715",
            "imbalance_side" => "2",
            "imbalance_ref_price" => "253.83",
            "imbalance_near_price" => "253.93",
            "imbalance_far_price" => "253.98",
            "imbalance_action_type" => "PRE_CLOSE",
            "imbalance_time" => 1_774_272_599_000
          },
          overrides
        )
      ]
    end

    test "the imbalance comes back with the venue's three prices" do
      assert {:ok, %Types.AuctionImbalance{} = imbalance} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(noii_body()),
                 retry_attempts: 0
               )

      assert imbalance.auction == :closing
      assert Decimal.equal?(imbalance.reference_price, Decimal.new("253.83"))
      assert Decimal.equal?(imbalance.near_price, Decimal.new("253.93"))
      assert Decimal.equal?(imbalance.far_price, Decimal.new("253.98"))
      assert Decimal.equal?(imbalance.paired_quantity, Decimal.new("701859"))
    end

    test "the side is the venue's raw value, not an atom" do
      # The venue documents `imbalance_side` with the example "2" and does not say what 2
      # means. Guessing it backwards tells a caller there is unmatched buying when there is
      # selling, at the moment of the day with the most volume behind it.
      assert {:ok, imbalance} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(noii_body()),
                 retry_attempts: 0
               )

      assert imbalance.side == "2"
      refute imbalance.side == :sell
    end

    test "the venue's time and observed_at are both carried, and they differ" do
      # Outside the auction window the venue returns the LAST imbalance. Without both times
      # a caller cannot tell this morning's from a running one.
      assert {:ok, imbalance} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(noii_body()),
                 retry_attempts: 0
               )

      assert imbalance.venue_time == DateTime.from_unix!(1_774_272_599_000, :millisecond)
      assert imbalance.observed_at
      assert DateTime.compare(imbalance.observed_at, imbalance.venue_time) == :gt
    end

    test "an undated imbalance leaves venue_time nil rather than borrowing observed_at" do
      # `nil` says the venue did not stamp it. Copying observed_at across would make a
      # stale imbalance look like a fresh one.
      body = noii_body() |> put_in([Access.at(0), "imbalance_time"], nil)

      assert {:ok, imbalance} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert imbalance.venue_time == nil
      assert imbalance.observed_at
    end

    test "the two auctions are two different requests" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(noii_body()))
      end

      assert {:ok, _opening} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :opening,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, opening}
      assert opening =~ "imbalance_action_type=PRE_OPEN"

      assert {:ok, _closing} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, closing}
      assert closing =~ "imbalance_action_type=PRE_CLOSE"
    end

    test "no auction is an error, and nothing is sent" do
      # Opening and closing are different auctions with different windows. Choosing one
      # would answer a question nobody asked.
      exploding = fn _conn -> raise "must not ask for an imbalance without an auction" end

      assert {:error, :auction_required} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an auction the venue does not have is an error" do
      exploding = fn _conn -> raise "must not ask for an auction the venue lacks" end

      assert {:error, {:unsupported_auction, :midday}} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :midday,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the ratio is available and reflects the venue's own two numbers" do
      assert {:ok, imbalance} =
               Rest.get_auction_imbalance("AAPL", @credentials,
                 auction: :closing,
                 plug: responding(noii_body()),
                 retry_attempts: 0
               )

      ratio = Types.AuctionImbalance.imbalance_ratio(imbalance)
      assert Decimal.compare(ratio, Decimal.new("0")) == :gt
      assert Decimal.compare(ratio, Decimal.new("1")) == :lt
    end
  end
end
