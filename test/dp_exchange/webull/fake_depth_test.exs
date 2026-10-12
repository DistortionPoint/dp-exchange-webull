defmodule DpExchange.Webull.FakeDepthTest do
  @moduledoc """
  The Fake's order book honours `:depth` as levels per side, as the real request sends it
  (Core's assertion 38). Absent, it returns the whole canned ladder.
  """
  use ExUnit.Case, async: true

  alias DpExchange.Webull.Fake

  @credentials %{app_key: "k", app_secret: "s"}

  test ":depth caps the levels on each side; absent, the whole ladder comes back" do
    assert {:ok, book} = Fake.get_order_book("AAPL", credentials: @credentials, depth: 1)
    assert length(book.bids) == 1
    assert length(book.asks) == 1

    assert {:ok, whole} = Fake.get_order_book("AAPL", credentials: @credentials)
    assert length(whole.bids) == 2
    assert length(whole.asks) == 2
  end

  test "a depth deeper than the ladder returns the whole ladder, not an error" do
    assert {:ok, book} = Fake.get_order_book("AAPL", credentials: @credentials, depth: 50)
    assert length(book.bids) == 2
    assert length(book.asks) == 2
  end

  test "a depth the real request refuses is refused here too, ahead of credentials" do
    assert {:error, {:invalid_option, :depth, 0}} = Fake.get_order_book("AAPL", depth: 0)

    assert {:error, {:invalid_option, :depth, "5"}} =
             Fake.get_order_book("AAPL", credentials: @credentials, depth: "5")

    assert {:error, {:invalid_option, :depth, 11}} =
             Fake.get_order_book("AAPL",
               credentials: @credentials,
               category: "US_FUTURES",
               depth: 11
             )
  end
end
