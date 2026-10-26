defmodule DpExchange.Webull.Issue12RejectedSymbolsTest do
  @moduledoc """
  Issue #12: a feed kept re-sending symbols the venue had refused as `INVALID_SYMBOL`, about a
  thousand warnings in 35 minutes after one subscribe at boot.

  The venue refuses an UNSUBSCRIBE naming a symbol it does not carry exactly as it refuses a
  subscribe: the whole request, 417 `INVALID_SYMBOL`. The earlier tests' venue answered every
  unsubscribe 200, so the loop never closed under them. The venue here refuses both, which is
  what the reporter's feed was talking to.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Webull.Feed

  @subscribe "/market-data/streaming/subscribe"
  @unsubscribe "/market-data/streaming/unsubscribe"

  # A venue that does not carry `unknown` (native symbols): any subscribe or unsubscribe naming
  # one of them is refused whole, naming every one it carried.
  defp venue(unknown) do
    test_pid = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      symbols = Jason.decode!(body)["symbols"]
      send(test_pid, {:request, conn.request_path, symbols})

      case Enum.filter(symbols, &(&1 in unknown)) do
        [] ->
          Req.Test.json(conn, %{"code" => "200"})

        named ->
          conn
          |> Plug.Conn.put_status(417)
          |> Req.Test.json(%{
            "error_code" => "INVALID_SYMBOL",
            "message" => "The symbols does not exist in the category. [#{Enum.join(named, ", ")}]"
          })
      end
    end
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(25)
        wait_until(fun, deadline)
    end
  end

  defp shard_symbols(feed, index), do: :sys.get_state(feed).shards[index].symbols

  # Every request received within `ms`.
  defp drain(ms, acc \\ []) do
    receive do
      {:request, _path, _symbols} = request -> drain(ms, [request | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp start_venue_feed(shard, wanted, unknown, limiter) do
    feed =
      start_feed(
        shards: %{0 => shard},
        credentials: credentials(),
        limiter: limiter,
        plug: venue(unknown),
        retry_attempts: 0
      )

    :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(wanted)})
    feed
  end

  test "a blind resubscribe refused INVALID_SYMBOL trims the shard and sends nothing more",
       %{limiter: limiter} do
    shard = %{connected_shard("s-i12-a") | symbols: ["AAA-USD", "BAD-USD"]}
    feed = start_venue_feed(shard, ["AAA-USD", "BAD-USD"], ["BADUSD"], limiter)

    send(feed, :resubscribe)

    assert_receive {:request, @subscribe, ["AAAUSD", "BADUSD"]}, 5_000
    wait_until(fn -> shard_symbols(feed, 0) == ["AAA-USD"] end)

    # The loop was an unsubscribe of BADUSD, refused, reverted and re-planned, over and over.
    assert drain(1_000) == []
    assert Map.has_key?(:sys.get_state(feed).rejected, "BAD-USD")
  end

  test "an unsubscribe refused for a symbol the venue no longer carries is sent again without it",
       %{limiter: limiter} do
    shard = %{connected_shard("s-i12-b") | symbols: ["GOOD-USD", "GONE-USD"]}
    feed = start_venue_feed(shard, ["GOOD-USD", "GONE-USD"], ["GONEUSD"], limiter)

    assert :ok =
             Feed.unsubscribe(
               feed,
               ["GOOD-USD", "GONE-USD"],
               subscribe_opts(limiter, plug: venue(["GONEUSD"]))
             )

    assert_receive {:request, @unsubscribe, ["GOODUSD", "GONEUSD"]}
    assert_receive {:request, @unsubscribe, ["GOODUSD"]}
    assert shard_symbols(feed, 0) == []
    assert drain(500) == []
  end

  test "an unsubscribe refused naming nothing it sent is answered as refused, not looped on",
       %{limiter: limiter} do
    shard = %{connected_shard("s-i12-c") | symbols: ["GOOD-USD"]}
    feed = start_venue_feed(shard, ["GOOD-USD"], [], limiter)

    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(body)["symbols"]})

      conn
      |> Plug.Conn.put_status(417)
      |> Req.Test.json(%{
        "error_code" => "INVALID_SYMBOL",
        "message" => "The symbols does not exist in the category. [OTHERUSD]"
      })
    end

    assert {:error, {:invalid_symbols, ["OTHER-USD"]}} =
             Feed.unsubscribe(feed, ["GOOD-USD"], subscribe_opts(limiter, plug: plug))

    # Each primary retry is one request; none of them is followed by a re-plan of its own.
    sent = drain(500)
    assert sent != []
    assert length(sent) <= 6
    assert Enum.all?(sent, &match?({:request, @unsubscribe, ["GOODUSD"]}, &1))
  end

  test "a post-CONNACK replay refused INVALID_SYMBOL is replayed without what it named",
       %{limiter: limiter} do
    shard = %{
      connected_shard("s-i12-d")
      | symbols: ["AAA-USD", "BAD-USD"],
        connected?: false
    }

    feed = start_venue_feed(shard, ["AAA-USD", "BAD-USD"], ["BADUSD"], limiter)

    send(feed, {:dp_exchange, :webull, link_up("s-i12-d")})

    assert_receive {:request, @subscribe, ["AAAUSD", "BADUSD"]}, 5_000
    # Every other symbol was refused with BADUSD, on a connection just up: sent again at once.
    assert_receive {:request, @subscribe, ["AAAUSD"]}, 5_000
    assert drain(500) == []
    assert shard_symbols(feed, 0) == ["AAA-USD"]
  end

  test "a caller parked on a connecting shard is answered by the replay that succeeded",
       %{limiter: limiter} do
    shard = %{connected_shard("s-i12-e") | connected?: false}
    feed = start_venue_feed(shard, [], ["BADUSD"], limiter)
    opts = subscribe_opts(limiter, plug: venue(["BADUSD"]))

    task = Task.async(fn -> Feed.subscribe(feed, ["AAA-USD", "BAD-USD"], opts) end)
    wait_until(fn -> :sys.get_state(feed).shards[0].reply_to not in [nil, []] end)

    send(feed, {:dp_exchange, :webull, link_up("s-i12-e")})

    assert :ok = Task.await(task, 10_000)
    assert_receive {:request, @subscribe, refused}, 5_000
    assert Enum.sort(refused) == ["AAAUSD", "BADUSD"]
    assert_receive {:request, @subscribe, ["AAAUSD"]}, 5_000
  end

  test "the moduledoc records that a refused symbol is never unsubscribed" do
    {:docs_v1, _anno, _lang, _format, %{"en" => text}, _meta, _entries} = Code.fetch_docs(Feed)
    assert text =~ "A refused symbol is never unsubscribed"
  end
end
