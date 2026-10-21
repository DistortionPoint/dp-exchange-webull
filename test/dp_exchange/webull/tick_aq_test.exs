defmodule DpExchange.Webull.TickAqTest do
  @moduledoc """
  Tick AQ: numbers and identifiers from venue text, configuration and option validation, and
  state that must not outlive its purpose. Every test names what the old code did.

    * a quantity finer than the venue's documented places was sent as typed;
    * an increment the venue sent and this package could not read was `nil`, the answer for
      "the venue publishes none";
    * a venue time or session id of any length was parsed or copied whole;
    * feed options that could not schedule a timer were accepted and failed in somebody's call;
    * `:ssl_options` given to the tree was dropped;
    * two trees of one venue (production and sandbox) had one child id;
    * `state.rejected` kept every symbol the venue ever named, and an emptied shard kept its
      socket for the life of the node.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.{Fanout, Notice}
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Feed, Rest, Socket, Subscription}

  @account "93IUJ28O9VO2KBGHDHR4H9"

  defp json_plug(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp crypto_order(quantity) do
    %{
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: quantity,
      price: "40000",
      client_order_id: "aq-order"
    }
  end

  defp event_order(quantity) do
    Map.merge(crypto_order(quantity), %{
      symbol: "KXGDP-26-T3",
      instrument_type: :event,
      time_in_force: :day
    })
  end

  defp place(request, extra) do
    Rest.place_order(credentials(), request, [account_id: @account, retry_attempts: 0] ++ extra)
  end

  defp placed_plug(test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([%{"client_order_id" => "aq-order"}]))
    end
  end

  describe "a quantity finer than the venue documents is refused, never rounded" do
    test "a crypto quantity with a ninth decimal place is refused before any request" do
      for bad <- ["0.123456789", Decimal.new("0.123456789"), "1.50000000000", "1e-9"] do
        assert {:error, {:invalid_quantity, ^bad}} = place(crypto_order(bad), plug: exploding())
      end
    end

    test "eight places, and whole numbers, are sent as written" do
      written = [{"0.12345678", "0.12345678"}, {3, "3"}, {Decimal.new("100"), "100"}]

      for {quantity, wire} <- written do
        assert {:ok, %{id: "aq-order"}} = place(crypto_order(quantity), plug: placed_plug(self()))

        assert_receive {:sent, %{"new_orders" => [%{"quantity" => ^wire}]}}
      end
    end

    test "an event contract takes at most two places" do
      for bad <- ["0.125", Decimal.new("1.001")] do
        assert {:error, {:invalid_quantity, ^bad}} = place(event_order(bad), plug: exploding())
      end

      assert {:ok, %{id: "aq-order"}} = place(event_order("0.25"), plug: placed_plug(self()))

      assert_receive {:sent, %{"new_orders" => [%{"quantity" => "0.25"}]}}
    end

    test "a stock quantity may be fractional, and no places are judged" do
      request =
        Map.merge(crypto_order("0.123456789012"), %{symbol: "AAPL", instrument_type: :equity})

      assert {:ok, %{id: "aq-order"}} = place(request, plug: placed_plug(self()))
      assert_receive {:sent, %{"new_orders" => [%{"quantity" => "0.123456789012"}]}}
    end

    test "the Fake refuses and accepts exactly what the real path does" do
      assert {:error, {:invalid_quantity, "0.123456789"}} =
               Fake.place_order(credentials(), crypto_order("0.123456789"), account_id: @account)

      assert {:ok, _order} =
               Fake.place_order(credentials(), crypto_order("0.12345678"), account_id: @account)
    end

    test "an amended event quantity is judged as a placed one is, in the Fake too" do
      opts = [instrument_type: :event, order_type: :limit, account_id: @account]

      assert {:error, {:invalid_quantity, "1.234"}} =
               Rest.replace_order(
                 credentials(),
                 "aq-order",
                 %{quantity: "1.234"},
                 opts ++ [plug: exploding(), retry_attempts: 0]
               )

      assert {:error, {:invalid_quantity, "1.234"}} =
               Fake.replace_order(credentials(), "aq-order", %{quantity: "1.234"}, opts)
    end
  end

  describe "quantization reports what the venue sent, or refuses" do
    @crypto_row %{
      "symbol" => "BTCUSD",
      "price_step" => "0.01",
      "lot_size" => "0.00000001",
      "min_trade_qty" => "0.0001",
      "max_trade_qty" => "1000",
      "min_trade_amt" => "1",
      "max_trade_amt" => "100000",
      "status" => "OC"
    }

    defp quantize(row, symbol \\ "BTC-USD") do
      Rest.quantization(symbol, credentials(),
        plug: json_plug(%{"data" => [row]}),
        retry_attempts: 0
      )
    end

    test "a figure that was sent and cannot be read is an error, not the nil of 'none'" do
      cases = [
        {"price_step", "abc", {:invalid_decimal, :price_step, "abc"}},
        {"lot_size", "NaN", {:invalid_decimal, :lot_size, "NaN"}},
        {"min_trade_qty", "x", {:invalid_decimal, :min_trade_qty, "x"}},
        {"max_trade_amt", "Infinity", {:invalid_decimal, :max_trade_amt, "Infinity"}}
      ]

      for {key, bad, expected} <- cases do
        assert {:error, expected} == quantize(Map.put(@crypto_row, key, bad))
      end
    end

    test "an increment of zero or less, and a negative limit, are refused" do
      cases = [
        {"price_step", "0", {:non_positive_size, :price_step, "0"}},
        {"lot_size", "-1", {:non_positive_size, :lot_size, "-1"}},
        {"min_trade_amt", "-5", {:non_positive_size, :min_trade_amt, "-5"}}
      ]

      for {key, bad, expected} <- cases do
        assert {:error, expected} == quantize(Map.put(@crypto_row, key, bad))
      end

      assert {:error, {:non_positive_size, :lot_size, "0"}} ==
               quantize(%{"symbol" => "AAPL", "lot_size" => "0"}, "AAPL")
    end

    test "a field the row does not carry stays nil, and a limit of zero is a limit" do
      row = @crypto_row |> Map.delete("min_trade_qty") |> Map.put("max_trade_qty", "0")

      assert {:ok, quantum} = quantize(row)
      assert quantum.min_quantity == nil
      assert Decimal.equal?(quantum.max_quantity, 0)
      assert Decimal.equal?(quantum.price_increment, Decimal.new("0.01"))
    end
  end

  describe "text from the venue is bounded before it is parsed or copied" do
    test "a bar time written in thousands of digits is refused, with a bounded echo" do
      huge = String.duplicate("9", 5_000)

      body = [
        %{
          "symbol" => "BTCUSD",
          "result" => [
            %{"time" => huge, "open" => "1", "high" => "1", "low" => "1", "close" => "1"}
          ]
        }
      ]

      assert {:error, {:unparseable_venue_timestamp, echoed}} =
               Rest.get_historical_prices("BTC-USD", "1m", [], credentials(),
                 plug: json_plug(body),
                 retry_attempts: 0
               )

      assert byte_size(echoed) == 32
    end

    test "a snapshot time that long is no time, and the price is still delivered" do
      huge = String.duplicate("9", 5_000)
      body = [%{"symbol" => "BTCUSD", "price" => "1", "last_trade_time" => huge}]

      assert {:ok, %{venue_time: nil}} =
               Rest.get_price("BTC-USD", credentials(), plug: json_plug(body), retry_attempts: 0)
    end

    test "a fiscal period that long is no label" do
      body = %{"data" => [%{"fiscal_period" => String.duplicate("1", 100)}]}

      assert {:ok, [%{fiscal_period: nil}]} =
               Rest.get_financials("AAPL", :balance_sheet, credentials(),
                 plug: json_plug(body),
                 retry_attempts: 0
               )
    end

    defp invalid_session_reply(message) do
      json_plug(%{"error_code" => "INVALID_SESSION", "message" => message}, 417)
    end

    defp subscribe_to_session(plug) do
      Subscription.subscribe("s0", ["BTC-USD"],
        credentials: credentials(),
        plug: plug,
        retry_attempts: 0
      )
    end

    test "a session id the venue names is read up to 128 characters, and no further" do
      issued = String.duplicate("a1", 16)

      assert {:error, {:invalid_session, ^issued}} =
               subscribe_to_session(
                 invalid_session_reply("Mqtt connection not exist for session:" <> issued)
               )

      too_long = String.duplicate("A", 5_000)

      assert {:error, {:invalid_session, nil}} =
               subscribe_to_session(
                 invalid_session_reply("Mqtt connection not exist for session:" <> too_long)
               )
    end

    test "a rejection naming thousands of symbols is read for the first 500" do
      listed = Enum.map_join(1..600, ", ", &"X#{&1}USD")

      body = %{
        "error_code" => "INVALID_SYMBOL",
        "message" => "The symbols does not exist in the category. [#{listed}]"
      }

      assert {:error, {:invalid_symbols, symbols}} = subscribe_to_session(json_plug(body, 417))

      assert length(symbols) == 500
      assert hd(symbols) == "X1-USD"
    end
  end

  describe "feed options are judged when the feed starts" do
    test "a timing or count option that cannot schedule a timer fails init, naming it" do
      Process.flag(:trap_exit, true)

      bad_options = [
        connack_timeout_ms: -1,
        reconcile_timeout_ms: 0,
        resubscribe_failure_limit: "12",
        stale_delivery_ms: 1.5,
        rejected_symbol_ttl_ms: false,
        open_retry_base_ms: :soon,
        open_retry_max_ms: -5,
        shard_spacing_ms: -1,
        idle_shard_ms: 0,
        socket_connect_timeout: "3s",
        socket_recv_timeout: 0
      ]

      for {key, bad} <- bad_options do
        assert {:error, {%ArgumentError{message: message}, _stack}} =
                 Feed.start_link([{:name, nil}, {key, bad}])

        assert message =~ inspect(key)
      end
    end

    test "a url the socket would refuse fails init, and is never echoed" do
      Process.flag(:trap_exit, true)

      for url <- ["ws://user:hunter2@data.example.test/mqtt", "http://x.test", "no url", 42] do
        assert {:error, {%ArgumentError{message: message}, _stack}} =
                 Feed.start_link(name: nil, url: url)

        assert message =~ ":url"
        refute message =~ "hunter2"
      end
    end

    test "valid values, a wss url and a spacing of zero are accepted" do
      feed =
        start_feed(
          url: "wss://data.example.test/mqtt",
          shard_spacing_ms: 0,
          socket_connect_timeout: 1_000,
          idle_shard_ms: 1
        )

      state = :sys.get_state(feed)
      assert state.socket_opts[:url] == "wss://data.example.test/mqtt"
      assert state.shard_spacing_ms == 0
      assert state.idle_shard_ms == 1
    end

    test "Socket.secure_url?/1 is the one judge of what a socket will dial" do
      assert Socket.secure_url?("wss://data.example.test/mqtt")
      assert Socket.secure_url?("ws://127.0.0.1:9/x")
      refute Socket.secure_url?("ws://data.example.test/mqtt")
      refute Socket.secure_url?("https://data.example.test")
      refute Socket.secure_url?(nil)
    end

    test ":ssl_options given to the tree reaches every socket it opens" do
      feed = start_feed(ssl_options: [cacerts: []])

      socket_opts = :sys.get_state(feed).socket_opts
      assert socket_opts[:ssl_options] == [cacerts: []]

      tls = Socket.connection_opts(socket_opts)[:ssl_options]
      assert tls[:cacerts] == []
      assert tls[:verify] == :verify_peer
    end
  end

  describe "a venue number is bounded to 34 digits" do
    @digits_34 "1234567890123456789012345678901234"
    @digits_35 "12345678901234567890123456789012345"

    defp read_price(price) do
      body = [%{"symbol" => "BTCUSD", "price" => price}]
      Rest.get_price("BTC-USD", credentials(), plug: json_plug(body), retry_attempts: 0)
    end

    test "a string of 34 digits is a price and one of 35 is unreadable, like NaN" do
      assert {:ok, %{price: price}} = read_price(@digits_34)
      assert Decimal.equal?(price, Decimal.new(@digits_34))

      assert {:error, {:invalid_decimal, :price, @digits_35}} = read_price(@digits_35)
      assert {:error, {:invalid_decimal, :price, "NaN"}} = read_price("NaN")
    end

    test "a JSON integer of 34 digits is a price and one of 40 is unreadable" do
      assert {:ok, %{price: price}} = read_price(String.to_integer(@digits_34))
      assert Decimal.equal?(price, Decimal.new(@digits_34))

      forty = 10 ** 39
      assert {:error, {:invalid_decimal, :price, ^forty}} = read_price(forty)
    end

    test "every type of number meets the same bound" do
      for readable <- [@digits_34, String.to_integer(@digits_34), Decimal.new(@digits_34)] do
        assert %Decimal{} = value = Rest.number_to_decimal(readable)
        assert Decimal.equal?(value, Decimal.new(@digits_34))
      end

      assert %Decimal{} = float = Rest.number_to_decimal(1.5)
      assert Decimal.equal?(float, Decimal.new("1.5"))

      assert Rest.number_to_decimal(@digits_35) == nil
      assert Rest.number_to_decimal(10 ** 40) == nil

      assert Rest.number_to_decimal(%Decimal{
               sign: 1,
               coef: String.to_integer(@digits_35),
               exp: 0
             }) == nil

      assert Rest.number_to_decimal(Decimal.new("NaN")) == nil
    end

    test "an order's quantity or price that long is refused before any request" do
      too_long = String.to_integer(@digits_35)

      for bad <- [
            @digits_35,
            too_long,
            %Decimal{sign: 1, coef: String.to_integer(@digits_35), exp: 0}
          ] do
        assert {:error, {:invalid_quantity, ^bad}} = place(crypto_order(bad), plug: exploding())

        assert {:error, {:invalid_price, ^bad}} =
                 place(%{crypto_order("1") | price: bad}, plug: exploding())
      end

      assert {:ok, %{id: "aq-order"}} = place(crypto_order(@digits_34), plug: placed_plug(self()))
    end

    defp varint(value) when value < 0x80, do: <<value>>

    defp varint(value),
      do: <<1::1, Bitwise.band(value, 0x7F)::7, varint(Bitwise.bsr(value, 7))::binary>>

    defp proto_field(number, value) do
      varint(Bitwise.bor(Bitwise.bsl(number, 3), 2)) <> varint(byte_size(value)) <> value
    end

    defp snapshot_frame(price) do
      basic = proto_field(1, "BTCUSD")
      payload = proto_field(1, basic) <> proto_field(2, "1787936147000") <> proto_field(3, price)
      body = <<8::16>> <> "snapshot" <> payload
      <<3::4, 0::4>> <> varint(byte_size(body)) <> body
    end

    defp socket_state do
      %{
        subscriber: self(),
        session_id: "s1",
        app_key: "k",
        buffer: <<>>,
        qos2_pending: MapSet.new(),
        connected?: false,
        ping: nil,
        last_heard_at: nil
      }
    end

    test "the stream reads 34 digits and refuses 35, reporting the drop" do
      frame = snapshot_frame(@digits_34)
      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, socket_state())

      assert_receive {:dp_exchange, :webull, %Quote{price: price}}, 5_000
      assert Decimal.equal?(price, Decimal.new(@digits_34))

      frame = snapshot_frame(@digits_35)
      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, socket_state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality}}, 5_000
      refute_receive {:dp_exchange, :webull, %Quote{}}, 500
    end
  end

  describe "a fractionable stock states no quantity increment" do
    defp stock_row(extra),
      do: Map.merge(%{"symbol" => "AAPL", "lot_size" => "1.0", "status" => "OC"}, extra)

    test "fractionable: true reports nil where lot_size would claim whole shares" do
      assert {:ok, quantum} = quantize(stock_row(%{"fractionable" => true}), "AAPL")
      assert quantum.quantity_increment == nil
    end

    test "fractionable: false, or no statement, keeps the lot_size" do
      for extra <- [%{"fractionable" => false}, %{}] do
        assert {:ok, quantum} = quantize(stock_row(extra), "AAPL")
        assert Decimal.equal?(quantum.quantity_increment, 1)
      end
    end

    test "an unreadable lot_size still refuses, fractionable or not" do
      row = stock_row(%{"fractionable" => true, "lot_size" => "abc"})
      assert {:error, {:invalid_decimal, :lot_size, "abc"}} == quantize(row, "AAPL")
    end
  end

  describe "a tree is started with options it reads" do
    test "an option nothing reads is refused before anything starts" do
      for key <- [:resubscribe_interval, :retry_attempts, :credential, :timeout] do
        assert {:error, {:unknown_option, ^key}} = Webull.start_link([{key, 1}])
        assert {:error, {:unknown_option, ^key}} = Webull.Supervisor.start_link([{key, 1}])
        assert {:error, {:unknown_option, ^key}} = Fake.start_link([{key, 1}])
      end
    end

    test "options that are not a keyword list are refused, credentials redacted" do
      secret = "AQ_START_SECRET"

      assert {:error, {:invalid_options, shown}} =
               Webull.start_link(%{credentials: %{app_key: "k", app_secret: secret}})

      refute inspect(shown) =~ secret
      assert {:error, {:invalid_options, [:oops]}} = Fake.start_link([:oops])
    end

    test "every key the tree, the feed and the socket read is accepted" do
      keys = [
        :name,
        :feed,
        :limiter,
        :ledger,
        :environment,
        :credentials,
        :plug,
        :rate_limit_blocking,
        :max_queue_len,
        :priority_symbols,
        :resubscribe_interval_ms,
        :resubscribe_failure_limit,
        :stale_delivery_ms,
        :connack_timeout_ms,
        :reconcile_timeout_ms,
        :rejected_symbol_ttl_ms,
        :open_retry_base_ms,
        :open_retry_max_ms,
        :shard_spacing_ms,
        :idle_shard_ms,
        :socket_connect_timeout,
        :socket_recv_timeout,
        :ssl_options,
        :url,
        :shards,
        :shard_capacity
      ]

      for key <- keys, do: assert(:ok == Webull.Options.check_start([{key, nil}]))
      assert Fake.start_link(name: :aq_fake, environment: :uat) == :ignore
    end

    test "a tree with documented options starts, and a mistyped one does not" do
      unique = System.unique_integer([:positive])

      opts = [
        name: :"aq_sup_#{unique}",
        feed: :"aq_feed_#{unique}",
        limiter: :"aq_lim_#{unique}",
        resubscribe_interval_ms: 300_000
      ]

      assert {:ok, pid} = Webull.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
      assert :sys.get_state(opts[:feed]).resubscribe_interval_ms == 300_000

      assert {:error, {:unknown_option, :resubscribe_interval}} =
               Webull.start_link(name: :"aq_typo_#{unique}", resubscribe_interval: 300_000)
    end
  end

  describe "two trees of one venue have two child ids" do
    test "production keeps its id, the sandbox gets its own, a name wins" do
      assert %{id: DpExchange.Webull} = Webull.child_spec([])
      assert %{id: DpExchange.Webull} = Webull.child_spec(environment: :production)
      assert %{id: DpExchange.Webull.Uat} = Webull.child_spec(environment: :uat)
      assert %{id: :mine} = Webull.child_spec(name: :mine, environment: :uat)
    end

    test "an environment that is neither raises where the spec is built" do
      assert_raise ArgumentError, ~r/unknown Webull environment/, fn ->
        Webull.child_spec(environment: :staging)
      end
    end
  end

  describe "a refusal is remembered only while its symbol is wanted" do
    defp idle, do: spawn(fn -> Process.sleep(:infinity) end)

    defp future, do: System.monotonic_time(:millisecond) + 3_600_000

    test "a symbol nobody wants is reported in the notice and not kept" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      want(feed, ["AAA-USD"])

      send(
        feed,
        {:reconcile_done, {:background, 0}, {:error, {:invalid_symbols, ["AAA-USD", "ZZZ-USD"]}}}
      )

      assert_receive {:dp_exchange, :webull, %Notice{kind: :refusal} = notice}, 5_000
      assert notice.details.symbols == ["AAA-USD", "ZZZ-USD"]
      assert Map.keys(:sys.get_state(feed).rejected) == ["AAA-USD"]
    end

    test "unsubscribe forgets the refusals of what it stops wanting", %{limiter: limiter} do
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["AAA-USD", "BBB-USD"]),
            rejected: %{"AAA-USD" => future(), "BBB-USD" => future()}
        }
      end)

      assert :ok = Feed.unsubscribe(feed, ["AAA-USD"], subscribe_opts(limiter))
      assert Map.keys(:sys.get_state(feed).rejected) == ["BBB-USD"]
    end

    test "update_symbols keeps the refusals of the symbols it keeps and no others",
         %{limiter: limiter} do
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["AAA-USD", "BBB-USD"]),
            rejected: %{"AAA-USD" => future(), "BBB-USD" => future()}
        }
      end)

      assert :ok = Feed.update_symbols(feed, ["BBB-USD"], subscribe_opts(limiter))
      assert Map.keys(:sys.get_state(feed).rejected) == ["BBB-USD"]
    end

    test "the death of the last data subscriber releases the symbols and their refusals" do
      feed = start_feed()
      doomed = idle()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | subscribers: MapSet.new([doomed]),
            monitors: Fanout.watch(doomed, state.monitors),
            wanted: MapSet.new(["AAA-USD"]),
            rejected: %{"AAA-USD" => future()}
        }
      end)

      ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^ref, :process, ^doomed, _reason}, 5_000
      # A call is answered only after the feed has handled its own `:DOWN`.
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert MapSet.size(state.wanted) == 0
      assert state.rejected == %{}
    end
  end

  describe "a shard with nothing to carry does not hold its socket for ever" do
    defp idle_shard(session) do
      socket = idle()
      on_exit(fn -> Process.exit(socket, :kill) end)
      {%{connected_shard(session) | socket: socket}, socket}
    end

    defp settle_tick(feed) do
      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)
      :sys.get_state(feed)
    end

    defp long_ago, do: System.monotonic_time(:millisecond) - 700_000

    test "the first tick that sees it idle only notes the instant; a later one closes it" do
      {shard, socket} = idle_shard("idle-0")
      ref = Process.monitor(socket)
      feed = start_feed(shards: %{0 => shard})

      state = settle_tick(feed)
      assert Map.has_key?(state.idle_since, 0)
      assert Map.has_key?(state.shards, 0)
      refute_receive {:DOWN, ^ref, :process, ^socket, _reason}, 500

      :sys.replace_state(feed, &%{&1 | idle_since: %{0 => long_ago()}})

      state = settle_tick(feed)
      refute Map.has_key?(state.shards, 0)
      assert state.idle_since == %{}
      assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    end

    test "a shard somebody is parked on is not idle" do
      {shard, socket} = idle_shard("parked-0")
      waiter = {{self(), make_ref()}, []}
      feed = start_feed(shards: %{0 => %{shard | connected?: false, reply_to: [waiter]}})

      :sys.replace_state(feed, &%{&1 | idle_since: %{0 => long_ago()}})

      state = settle_tick(feed)
      assert Map.has_key?(state.shards, 0)
      assert state.idle_since == %{}
      assert Process.alive?(socket)
    end

    test "a shard that took a symbol again loses its idle mark", %{limiter: limiter} do
      {shard, socket} = idle_shard("busy-0")

      feed =
        start_feed(
          shards: %{0 => %{shard | symbols: ["BTC-USD"]}},
          credentials: credentials(),
          limiter: limiter,
          plug: fn conn -> Req.Test.json(conn, %{"code" => "200"}) end,
          retry_attempts: 0
        )

      :sys.replace_state(feed, &%{&1 | idle_since: %{0 => long_ago()}})

      state = settle_tick(feed)
      assert Map.has_key?(state.shards, 0)
      assert state.idle_since == %{}
      assert Process.alive?(socket)
    end
  end
end
