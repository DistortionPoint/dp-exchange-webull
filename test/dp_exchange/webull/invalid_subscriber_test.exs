defmodule DpExchange.Webull.InvalidSubscriberTest do
  # A subscriber that `Core.Fanout.resolve/1` has no clause for (anything but a pid or an
  # atom) used to be stored by `Feed` and then raised `FunctionClauseError` inside the one
  # shared process on the first delivery. It is refused at the door now, in `Feed` and in the
  # fake alike. Every name below is unique to the test, so this file is async-safe.
  use ExUnit.Case, async: true

  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Feed}

  setup do
    name = :"invalid_subscriber_feed_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link(name: name)
    {:ok, feed: feed}
  end

  test "Feed.subscribe/3 refuses a subscriber that is not a pid or a name, and stays up",
       %{feed: feed} do
    for bad <- ["nobody", {:global, :nobody}, 42, [self()]] do
      assert Feed.subscribe(feed, ["BTC-USD"], to: bad) == {:error, {:invalid_subscriber, bad}}
    end

    assert Process.alive?(feed)
    state = :sys.get_state(feed)
    assert state.subscribers == MapSet.new()
    assert state.monitors == %{}
    assert state.wanted == MapSet.new()
  end

  test "Feed.subscribe_notices/2 refuses the same subscribers and records nothing",
       %{feed: feed} do
    assert Feed.subscribe_notices(feed, to: "nobody") ==
             {:error, {:invalid_subscriber, "nobody"}}

    assert Feed.subscribe_notices(feed, to: {:via, Registry, :nobody}) ==
             {:error, {:invalid_subscriber, {:via, Registry, :nobody}}}

    assert Process.alive?(feed)
    assert :sys.get_state(feed).notice_subscribers == MapSet.new()
  end

  test "a symbol list that is refused is reported ahead of a bad subscriber", %{feed: feed} do
    assert {:error, {:invalid_symbols, [""]}} = Feed.subscribe(feed, [""], to: "nobody")
  end

  test "a pid and a registered name are still accepted", %{feed: feed} do
    assert Feed.subscribe_notices(feed, to: self()) == :ok
    assert Feed.subscribe_notices(feed, to: :some_registered_consumer) == :ok

    assert :sys.get_state(feed).notice_subscribers ==
             MapSet.new([self(), :some_registered_consumer])
  end

  test "the facade answers the refusal instead of crashing the feed", %{feed: feed} do
    assert Webull.subscribe(["BTC-USD"], feed: feed, to: "nobody") ==
             {:error, {:invalid_subscriber, "nobody"}}

    assert Webull.subscribe_notices(feed: feed, to: 42) == {:error, {:invalid_subscriber, 42}}
    assert Process.alive?(feed)
  end

  test "the fake refuses the same subscribers" do
    assert Fake.subscribe(["BTC-USD"], to: "nobody") ==
             {:error, {:invalid_subscriber, "nobody"}}

    assert Fake.subscribe_notices(to: {:global, :nobody}) ==
             {:error, {:invalid_subscriber, {:global, :nobody}}}

    assert Fake.coverage() == %{}
    assert Fake.subscribe_notices(to: self()) == :ok
  end
end
