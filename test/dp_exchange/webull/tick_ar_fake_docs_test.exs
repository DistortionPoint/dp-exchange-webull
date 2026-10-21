defmodule DpExchange.Webull.TickArFakeDocsTest do
  @moduledoc """
  Tick AR, lens V: what `DpExchange.Webull.Fake`'s documentation says, held against what it
  does. Each case here was a doc or comment claim the code did not keep.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull.Fake

  @credentials %{app_key: "key", app_secret: "secret"}
  @opts [credentials: @credentials]

  describe "wanted/1 is what was asked for, as the real feed's is" do
    test "a symbol the fake does not model is wanted and is not covered" do
      assert :ok = Fake.subscribe(["BTC-USD", "DOGE-USD"], @opts)

      assert Fake.wanted() == ["BTC-USD", "DOGE-USD"]
      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "unsubscribing and updating change what is wanted" do
      assert :ok = Fake.subscribe(["ETH-USD", "DOGE-USD", "BTC-USD"], @opts)
      assert Fake.wanted() == ["BTC-USD", "DOGE-USD", "ETH-USD"]

      assert :ok = Fake.unsubscribe(["DOGE-USD"], @opts)
      assert Fake.wanted() == ["BTC-USD", "ETH-USD"]

      assert :ok = Fake.update_symbols(["SOL-USD", "ZZZ-USD"], @opts)
      assert Fake.wanted() == ["SOL-USD", "ZZZ-USD"]
      assert Map.keys(Fake.coverage()) == ["SOL-USD"]
    end

    test "a subscriber that cannot be reached leaves the symbol wanted and uncovered" do
      nobody = :"tick_ar_nobody_#{System.unique_integer([:positive])}"

      assert :ok = Fake.subscribe(["BTC-USD"], [to: nobody] ++ @opts)

      assert Fake.wanted() == ["BTC-USD"]
      assert Fake.coverage() == %{}
    end
  end

  describe "update_watchlist/2 and the canned wl-1" do
    test "an id this process does not hold is refused, as the other writes refuse it" do
      assert {:refused, :not_found} = Fake.update_watchlist("nope", [name: "x"] ++ @opts)
      assert {:refused, :not_found} = Fake.delete_watchlist("nope", @opts)
    end

    test "a deleted watchlist cannot be renamed" do
      assert {:ok, %{id: id}} = Fake.create_watchlist("Gone", ["AAPL"], @opts)
      assert {:ok, :ok} = Fake.delete_watchlist(id, @opts)

      assert {:refused, :not_found} = Fake.update_watchlist(id, [name: "Back"] ++ @opts)
    end

    test "renaming wl-1 shows in the listing, once, and keeps its canned members" do
      assert {:ok, %{id: "wl-1", name: "Renamed"}} =
               Fake.update_watchlist("wl-1", [name: "Renamed"] ++ @opts)

      assert {:ok, listed} = Fake.list_watchlists(@opts)
      assert [%{name: "Renamed"}] = Enum.filter(listed, &(&1.id == "wl-1"))

      assert {:ok, %{symbols: ["AAPL", "GOOG"]}} = Fake.get_watchlist("wl-1", @opts)
    end

    test "a membership write on wl-1 does not list it twice" do
      assert {:ok, %{"success" => true}} =
               Fake.add_watchlist_instruments("wl-1", ["MSFT"], @opts)

      assert {:ok, listed} = Fake.list_watchlists(@opts)
      assert [%{name: "My Tech Stocks"}] = Enum.filter(listed, &(&1.id == "wl-1"))

      assert {:ok, %{symbols: ["AAPL", "GOOG", "MSFT"]}} = Fake.get_watchlist("wl-1", @opts)
    end

    test "a deleted wl-1 is not listed, and a rename of it is refused" do
      assert {:ok, :ok} = Fake.delete_watchlist("wl-1", @opts)

      assert {:ok, listed} = Fake.list_watchlists(@opts)
      assert Enum.filter(listed, &(&1.id == "wl-1")) == []

      assert {:refused, :not_found} = Fake.update_watchlist("wl-1", [name: "X"] ++ @opts)
    end
  end

  describe "the reads with no error channel raise, as the moduledoc says" do
    test "an option nothing reads is an ArgumentError, not an answer" do
      for call <- [
            fn -> Fake.coverage(bogus: 1) end,
            fn -> Fake.wanted(bogus: 1) end,
            fn -> Fake.coverage_by_kind(bogus: 1) end,
            fn -> Fake.streaming?(bogus: 1) end,
            fn -> Fake.live?(bogus: 1) end
          ] do
        assert_raise ArgumentError, call
      end
    end
  end
end
