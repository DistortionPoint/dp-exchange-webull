defmodule DpExchange.Webull.TickAmSubTypesTest do
  @moduledoc """
  `:sub_types` is a subscription the feed remembers, and a bad one is refused at the boundary.

  Found by reading `Feed.replayable/2` (tick AM): the option rode in the call's own `opts` and
  nowhere else, so every request the feed made for itself afterwards (the replay on a
  CONNACK, the blind resubscribe, a later call naming none) asked the venue for the default
  three types whatever the caller had asked for. And a `:sub_types` that is not a non-empty
  list of strings was found only once a shard had been opened and the request was about to go
  out; the facade and the fake now refuse it with the other option checks, in the same order.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Feed, Rest}

  @subscribe "/market-data/streaming/subscribe"
  @all_types ["SNAPSHOT", "QUOTE", "TICK"]

  defp capturing(test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"code" => "200"}))
    end
  end

  defp connected_feed(limiter) do
    start_feed(
      shards: %{0 => connected_shard("s0")},
      credentials: credentials(),
      limiter: limiter
    )
  end

  describe "the feed remembers what it was told to ask the venue for" do
    test "the replay after a CONNACK asks for the sub_types the caller named", %{
      limiter: limiter
    } do
      me = self()
      feed = connected_feed(limiter)
      opts = subscribe_opts(limiter, sub_types: ["SNAPSHOT"], plug: capturing(me))

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], opts)
      assert_receive {:request, @subscribe, %{"sub_types" => ["SNAPSHOT"]}}, 5_000

      send(feed, {:dp_exchange, :webull, link_up("s0")})
      assert_receive {:request, @subscribe, %{"sub_types" => ["SNAPSHOT"]}}, 5_000
    end

    test "a later subscribe that names none keeps asking for the remembered ones", %{
      limiter: limiter
    } do
      me = self()
      feed = connected_feed(limiter)
      first = subscribe_opts(limiter, sub_types: ["QUOTE"], plug: capturing(me))
      second = subscribe_opts(limiter, plug: capturing(me))

      assert :ok = Feed.subscribe(feed, ["BTC-USD"], first)
      assert_receive {:request, @subscribe, %{"sub_types" => ["QUOTE"]}}, 5_000

      assert :ok = Feed.subscribe(feed, ["ETH-USD"], second)
      assert_receive {:request, @subscribe, %{"sub_types" => ["QUOTE"]}}, 5_000
    end

    test "a feed that was never told asks for all three", %{limiter: limiter} do
      me = self()
      feed = connected_feed(limiter)

      assert :ok =
               Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter, plug: capturing(me)))

      assert_receive {:request, @subscribe, %{"sub_types" => @all_types}}, 5_000
    end
  end

  describe "a :sub_types that is not a non-empty list of strings is refused before the feed" do
    test "the facade and the fake answer alike for subscribe, unsubscribe and update_symbols" do
      for bad <- ["SNAPSHOT", [], [:snapshot], {"SNAPSHOT"}, ["QUOTE", 1]],
          module <- [Webull, Fake],
          function <- [:subscribe, :unsubscribe, :update_symbols] do
        assert {:error, {:invalid_sub_types, ^bad}} =
                 apply(module, function, [["BTC-USD"], [sub_types: bad]])
      end
    end

    test "the symbols and the unknown options are judged first, as in the rest of the family" do
      for module <- [Webull, Fake] do
        assert {:error, {:invalid_symbols, nil}} = module.subscribe(nil, sub_types: [])

        assert {:error, {:unknown_option, :nope}} =
                 module.subscribe(["BTC-USD"], nope: 1, sub_types: [])
      end
    end

    test "a valid list is accepted by the fake" do
      opts = [sub_types: ["SNAPSHOT", "QUOTE"], credentials: credentials()]

      assert :ok = Fake.subscribe(["BTC-USD"], opts)
    end
  end

  describe "the fake needs credentials at the point the real feed first does" do
    @app_key_missing {:error, {:missing_required_field, :app_key}}

    test "touching a shard that is not open needs the App Key, answered by the call itself" do
      feed = start_feed(shards: %{})

      assert @app_key_missing == Feed.subscribe(feed, ["BTC-USD"], [])
      assert @app_key_missing == Fake.subscribe(["BTC-USD"], to: self())
      assert @app_key_missing == Fake.update_symbols(["BTC-USD"])
      assert Fake.coverage() == %{}
      assert Fake.wanted() == []
    end

    test "a call that changes nothing needs none" do
      feed = start_feed(shards: %{})

      assert :ok == Feed.subscribe(feed, [], [])
      assert :ok == Fake.subscribe([], to: self())
      assert :ok == Fake.update_symbols([])
      assert :ok == Fake.unsubscribe(["BTC-USD"])
    end

    test "with a shard open, a call that changes it is signed from its own credentials",
         %{limiter: limiter} do
      feed = connected_feed(limiter)
      missing = {:error, {:missing_credentials, :webull}}

      assert :ok == Feed.subscribe(feed, ["BTC-USD"], subscribe_opts(limiter))
      assert :ok == Fake.subscribe(["BTC-USD"], credentials: credentials())

      # Something new: signed from the call's own credentials, which it does not carry. The
      # fake answers what the real feed answers.
      real = Feed.subscribe(feed, ["ETH-USD"], limiter: limiter)
      assert real == missing
      assert real == Fake.subscribe(["ETH-USD"], to: self())
      assert missing == Fake.unsubscribe(["BTC-USD"])

      # A refused call changed nothing, in the feed as in the fake: the refused symbol is not
      # wanted, and a call that asks for what IS wanted has nothing to sign.
      assert Feed.wanted(feed) == ["BTC-USD"]
      assert Fake.wanted() == ["BTC-USD"]
      assert :ok == Feed.subscribe(feed, ["BTC-USD"], limiter: limiter)
      assert :ok == Fake.subscribe(["BTC-USD"], to: self())
      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "a refused unsubscribe or update_symbols leaves what was wanted wanted",
         %{limiter: limiter} do
      feed = connected_feed(limiter)

      assert :ok == Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], subscribe_opts(limiter))

      # No credentials on the call: the HTTP request cannot be signed, so the call is refused.
      missing = {:error, {:missing_credentials, :webull}}
      assert missing == Feed.unsubscribe(feed, ["ETH-USD"], limiter: limiter)
      assert Feed.wanted(feed) == ["BTC-USD", "ETH-USD"]

      assert missing == Feed.update_symbols(feed, ["SOL-USD"], limiter: limiter)
      assert Feed.wanted(feed) == ["BTC-USD", "ETH-USD"]
    end

    test "a refused subscribe on a feed with no shard leaves nothing wanted" do
      feed = start_feed(shards: %{})

      assert @app_key_missing == Feed.subscribe(feed, ["BTC-USD"], [])
      assert Feed.wanted(feed) == []
      assert :sys.get_state(feed).call_undo == %{}
    end
  end

  describe "the fake makes the fundamentals checks the real path makes before it signs" do
    @credentials %{app_key: "key", app_secret: "secret"}

    test "get_corporate_events/1 refuses a blank symbol alike" do
      expected = {:error, {:invalid_symbol, "  "}}

      assert expected == Rest.get_corporate_events(@credentials, symbol: "  ")
      assert expected == Fake.get_corporate_events(credentials: @credentials, symbol: "  ")
    end

    test "get_corporate_events/1 refuses a non-query category alike" do
      expected = {:error, {:invalid_option, :category, %{a: 1}}}
      opts = [symbol: "AAPL", category: %{a: 1}]

      assert expected == Rest.get_corporate_events(@credentials, opts)
      assert expected == Fake.get_corporate_events([credentials: @credentials] ++ opts)
    end

    test "get_filings/2 refuses a non-query category alike" do
      expected = {:error, {:invalid_option, :category, %{a: 1}}}

      assert expected == Rest.get_filings("AAPL", @credentials, category: %{a: 1})
      assert expected == Fake.get_filings("AAPL", credentials: @credentials, category: %{a: 1})
    end
  end

  describe "the fake's cash activity rows carry the fields the venue marks required" do
    @required ~w(account_id activity_sub_type activity_type biz_time currency id)
    @required_amounts ~w(net_amount trade_date)

    test "get_transactions/2 and get_transfers/2 rows are complete" do
      opts = [credentials: @credentials, account_id: "acct-1"]
      {:ok, transactions} = Fake.get_transactions(@credentials, opts)
      {:ok, transfers} = Fake.get_transfers(@credentials, opts)

      # A comprehension over no rows asserts nothing: both must hold rows to be judged.
      assert transactions != [] and transfers != []

      for row <- transactions ++ transfers, field <- @required ++ @required_amounts do
        assert is_binary(row[field]), "#{inspect(row["id"])} lacks #{field}"
      end
    end
  end
end
