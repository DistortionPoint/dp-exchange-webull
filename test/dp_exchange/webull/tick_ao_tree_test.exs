defmodule DpExchange.Webull.TickAoTreeTest do
  @moduledoc """
  Tick AO: several trees in one VM, and a feed that survives its own restart.

    * a tree started with only a distinct `name:` gets its own feed, limiter and ledger, and a
      facade call given the same `name:` addresses that tree and no other;
    * a tree with no `name:` keeps today's names exactly, and an explicit name still wins;
    * `Feed` writes what it was asked to do to the `Ledger` only when it ACCEPTED a change, and
      a restarted feed has the same wanted set and the same subscribers, tells them, and
      delivers to them again.

  No network: the HTTP half is a plug, and the shard the subscribe is made against is a
  pre-connected one injected into the feed, as the other feed tests do.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Webull.{Credentials, FeedCase, Ledger, Supervisor}

  @moduletag :capture_log

  @credentials %{app_key: "k", app_secret: "AO_TREE_SECRET_NOT_FOR_LOGS"}

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_tree(name) do
    start_supervised!({DpExchange.Webull, name: name, credentials: @credentials}, id: name)
    name
  end

  defp feed_of(name), do: Process.whereis(Supervisor.feed_name(name: name))

  defp ok_plug, do: fn conn -> Req.Test.json(conn, %{"code" => "200"}) end

  defp refusing_plug do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error_code":"AO_REFUSED"}))
    end
  end

  # A pre-connected shard 0, so a subscribe is answered by the plug and opens no socket.
  defp connect_shard(feed) do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)

    :sys.replace_state(feed, fn state ->
      shard = %{
        session_id: "ao-s0",
        socket: socket,
        connected?: true,
        symbols: [],
        reply_to: nil
      }

      %{state | shards: %{0 => shard}}
    end)
  end

  describe "names" do
    test "a tree with no name keeps today's names, and an explicit one wins" do
      assert Supervisor.feed_name([]) == DpExchange.Webull.Feed
      assert Supervisor.limiter_name([]) == DpExchange.Webull.RateLimiter
      assert Supervisor.ledger_name([]) == DpExchange.Webull.Ledger
      assert Supervisor.feed_name(environment: :uat) == DpExchange.Webull.UatFeed
      assert Supervisor.limiter_name(environment: :uat) == DpExchange.Webull.UatRateLimiter

      # The default supervisor name is not a custom one.
      assert Supervisor.feed_name(name: DpExchange.Webull.Supervisor) == DpExchange.Webull.Feed

      assert Supervisor.feed_name(name: :account_b) |> Atom.to_string() =~ "account_b.Feed"
      assert Supervisor.feed_name(name: :account_b, feed: Mine) == Mine
      assert Supervisor.limiter_name(name: :account_b, limiter: Mine) == Mine
    end

    test "two trees given only distinct names run side by side, each addressed by its name" do
      a = start_tree(unique_name("ao_a"))
      b = start_tree(unique_name("ao_b"))

      refute feed_of(a) == feed_of(b)
      assert is_pid(feed_of(a)) and is_pid(feed_of(b))

      for tree <- [a, b] do
        assert is_pid(Process.whereis(Supervisor.limiter_name(name: tree)))
        assert is_pid(Process.whereis(Supervisor.ledger_name(name: tree)))
      end

      :sys.replace_state(feed_of(a), &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      assert DpExchange.Webull.wanted(name: a) == ["BTC-USD"]
      assert DpExchange.Webull.wanted(name: b) == []

      # The REST half meters in the addressed tree's own limiter: a limiter that did not exist
      # would answer "Rate limiter unavailable".
      plug = fn conn -> Req.Test.json(conn, [%{"symbol" => "BTCUSD", "price" => "1.5"}]) end

      for tree <- [a, b] do
        assert {:ok, %Quote{price: price}} =
                 DpExchange.Webull.get_price("BTC-USD",
                   name: tree,
                   credentials: @credentials,
                   plug: plug,
                   retry_attempts: 0
                 )

        assert Decimal.equal?(price, Decimal.new("1.5"))
      end
    end
  end

  describe "a restarted feed" do
    test "has the same wanted set, tells its subscriber, and delivers to it again" do
      tree = start_tree(unique_name("ao_restart"))
      ledger = Supervisor.ledger_name(name: tree)
      feed = feed_of(tree)
      connect_shard(feed)

      opts = [name: tree, credentials: @credentials, plug: ok_plug(), retry_attempts: 0]

      assert DpExchange.Webull.subscribe(["BTC-USD"], opts) == :ok

      # Written when the change was accepted, with the credentials inside their struct.
      assert {:ok, %{wanted: ["BTC-USD"], subscribers: subscribers} = intent} =
               Ledger.fetch(ledger)

      assert subscribers == [self()]

      assert %Credentials{app_secret: "AO_TREE_SECRET_NOT_FOR_LOGS"} =
               intent.resubscribe_opts[:credentials]

      refute inspect(:sys.get_status(ledger), limit: :infinity) =~ "AO_TREE_SECRET"

      # A refused change is never written.
      # Blocking, so the tree's own limiter waits rather than throttling the second call.
      refusing =
        opts |> Keyword.put(:plug, refusing_plug()) |> Keyword.put(:rate_limit_blocking, true)

      assert {:error, {:refused, 400, _body}} =
               DpExchange.Webull.subscribe(["ETH-USD"], refusing)

      assert {:ok, %{wanted: ["BTC-USD"]}} = Ledger.fetch(ledger)
      assert DpExchange.Webull.wanted(name: tree) == ["BTC-USD"]

      Process.exit(feed, :kill)

      assert_receive {:dp_exchange, :webull,
                      %Notice{
                        kind: :coverage_change,
                        details: %{reason: :feed_restarted, symbols: ["BTC-USD"]}
                      }},
                     10_000

      restarted = feed_of(tree)
      assert is_pid(restarted)
      refute restarted == feed

      assert DpExchange.Webull.wanted(name: tree) == ["BTC-USD"]

      assert %Credentials{app_secret: "AO_TREE_SECRET_NOT_FOR_LOGS"} =
               :sys.get_state(restarted).resubscribe_opts[:credentials]

      send(restarted, {:dp_exchange, :webull, FeedCase.quote_for("BTC-USD")})
      assert_receive {:dp_exchange, :webull, %Quote{symbol: "BTC-USD"}}, 5_000
    end
  end
end
