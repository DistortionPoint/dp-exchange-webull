defmodule DpExchange.Webull.TickArDocsTest do
  @moduledoc """
  Tick AR, lens V: what the documentation says, held against what the code does.

  Every test here fails when a document and the code it describes part company, and names
  the claim it holds:

    * the README's callback counts are `capabilities/0`'s;
    * every endpoint declared the venue's own absence has a row in `negative-claims.md`;
    * every start option is named in `usage-rules.md`, with the default the feed starts with;
    * `usage-rules.md`'s table of the keys each function reads is `Options`' table;
    * the refusals `usage-rules.md` names are the ones the code returns;
    * a start option the feed refuses fails the tree's start, as the docs say, and does not
      raise in the caller;
    * a news item's `publish_time` is bounded like every other venue time it refuses.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Venue
  alias DpExchange.Webull
  alias DpExchange.Webull.{Feed, Options, Rest, Socket}

  @root Path.expand("../../..", __DIR__)

  @start_keys [
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

  # Each endpoint declared the venue's own absence, and a phrase `negative-claims.md` uses for
  # the row that records it (compared in lower case).
  @recorded %{
    get_staking_rates: "staking",
    get_staking_balances: "staking",
    get_staking_rewards: "staking",
    get_staking_history: "staking",
    stake: "staking",
    unstake: "staking",
    convert: "conversion",
    quote_conversion: "conversion",
    commit_conversion: "conversion",
    get_conversion: "conversion",
    get_trade_volume: "trade-volume",
    get_deposit_address: "withdrawal",
    list_approved_addresses: "withdrawal",
    estimate_withdrawal_fee: "withdrawal",
    withdraw: "withdrawal",
    list_payment_methods: "payment methods",
    get_payment_method: "payment methods",
    add_payment_method: "payment methods",
    transfer_internal: "transfers",
    request_approved_address: "allowlist",
    remove_approved_address: "allowlist",
    list_networks: "networks",
    list_fee_promos: "fee promos",
    get_fx_rate: "no fx",
    get_notional_balances: "notional",
    list_custody_fees: "custody",
    get_option_greeks: "greeks",
    preview_replace: "amendment",
    cancel_all_orders: "bulk cancel",
    close_position: "close-position",
    market_status: "market-status"
  }

  defp doc(path), do: @root |> Path.join(path) |> File.read!()

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  describe "the README's counts are capabilities/0's" do
    test "callbacks, experimental, unsupported, the venue's own absences and none proven" do
      readme = doc("README.md")

      assert [_whole, callbacks, experimental] =
               Regex.run(~r/(\d+) callbacks, of which \*\*(\d+) are declared/, readme)

      assert [_whole_unsupported, unsupported] =
               Regex.run(~r/`:experimental`\*\* and (\d+) `:unsupported`/, readme)

      assert [_whole_absent, absent] =
               Regex.run(~r/\*\*(\d+) are the venue's own absence\*\*/, readme)

      endpoints = Webull.capabilities().endpoints
      count = fn maturity -> Enum.count(endpoints, fn {_callback, m} -> m == maturity end) end

      assert String.to_integer(callbacks) == length(Venue.behaviour_info(:callbacks))
      assert String.to_integer(callbacks) == map_size(endpoints)
      assert String.to_integer(experimental) == count.(:experimental)
      assert String.to_integer(unsupported) == count.(:unsupported)
      assert String.to_integer(absent) == length(Webull.venue_does_not_serve())
      assert count.(:proven) == 0
    end
  end

  describe "every endpoint the venue does not serve is recorded in negative-claims.md" do
    test "the table covers exactly venue_does_not_serve/0, so a new entry needs a row" do
      declared = Webull.venue_does_not_serve() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert declared == @recorded |> Map.keys() |> Enum.sort()
    end

    test "each one has a row naming it" do
      claims = "docs/reference/webull/negative-claims.md" |> doc() |> String.downcase()

      for {callback, phrase} <- @recorded do
        assert claims =~ phrase, "#{callback}: negative-claims.md has no row saying #{phrase}"
      end
    end
  end

  describe "the feed's options are documented with the defaults the feed starts with" do
    test "every key the tree reads is named in usage-rules.md, and one it does not read is not" do
      rules = doc("usage-rules.md")

      for key <- @start_keys do
        assert :ok == Options.check_start([{key, nil}])
        assert rules =~ "`:#{key}`", "#{inspect(key)} is a start key usage-rules.md never names"
      end

      assert {:error, {:unknown_option, :idle_shard}} = Options.check_start(idle_shard: 1)
    end

    test "each default in the option table is the default the feed has" do
      state = :sys.get_state(start_feed())
      rules = doc("usage-rules.md")

      rows = [
        {:resubscribe_interval_ms, 60_000, "60_000, at least 1_000"},
        {:resubscribe_failure_limit, 12, "12"},
        {:stale_delivery_ms, 300_000, "300_000"},
        {:connack_timeout_ms, 10_000, "10_000"},
        {:reconcile_timeout_ms, 60_000, "60_000"},
        {:rejected_symbol_ttl_ms, 24 * 60 * 60 * 1_000, "24 hours"},
        {:shard_spacing_ms, 5_000, "5_000"},
        {:idle_shard_ms, 600_000, "600_000"},
        {:max_queue_len, 10_000, "10_000"}
      ]

      for {key, value, shown} <- rows do
        assert Map.fetch!(state, key) == value

        assert rules =~ "| `:#{key}` | #{shown}",
               "#{inspect(key)}: the table does not say #{shown}"
      end

      assert state.open_retry_base_ms == 1_000
      assert state.open_retry_max_ms == 60_000
      assert rules =~ "| `:open_retry_base_ms`, `:open_retry_max_ms` | 1_000, 60_000 |"
    end

    test "the socket budgets and the TLS default are the documented ones" do
      options = Socket.connection_opts([])

      assert options[:socket_connect_timeout] == 3_000
      assert options[:socket_recv_timeout] == 2_000
      assert options[:ssl_options][:verify] == :verify_peer

      rules = doc("usage-rules.md")
      assert rules =~ "| `:socket_connect_timeout`, `:socket_recv_timeout` | 3_000, 2_000 |"
      assert rules =~ "| `:ssl_options` | verified TLS |"
    end

    test "a start option the feed refuses fails the tree's start; it does not raise here" do
      Process.flag(:trap_exit, true)
      name = :"ar_docs_sup_#{System.unique_integer([:positive])}"

      assert {:error,
              {:shutdown,
               {:failed_to_start_child, Feed, {%ArgumentError{message: message}, _stack}}}} =
               Webull.start_link(name: name, idle_shard_ms: 0)

      assert message =~ ":idle_shard_ms"
    end
  end

  describe "usage-rules.md's table of the keys each function reads is Options' table" do
    defp key_rows do
      rules = doc("usage-rules.md")
      [_before, after_heading] = String.split(rules, "### The keys each function reads", parts: 2)
      [table, _rest] = String.split(after_heading, "A kind or screener the venue", parts: 2)

      table
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))
      |> Enum.reject(&(&1 =~ "get_fundamental/3" or &1 =~ "get_screener/2"))
    end

    defp row_functions(row) do
      ~r/`([a-z_?!]+)\/\d+`/
      |> Regex.scan(row |> String.split(" | ", parts: 2) |> hd())
      |> Enum.map(fn [_all, name] -> String.to_existing_atom(name) end)
    end

    defp row_keys(row) do
      keys = row |> String.split(" | ", parts: 2) |> List.last() |> String.trim()

      if String.starts_with?(keys, "none") do
        []
      else
        ~r/`:([a-z_]+)`/
        |> Regex.scan(keys)
        |> Enum.map(fn [_all, key] -> String.to_existing_atom(key) end)
      end
    end

    test "there are rows to compare" do
      assert length(key_rows()) > 25
    end

    test "every function a row names reads exactly the keys the row lists" do
      for row <- key_rows(), function <- row_functions(row) do
        assert Enum.sort(Options.own_keys(function)) == Enum.sort(row_keys(row)),
               "#{function}: usage-rules.md says #{inspect(row_keys(row))}"
      end
    end
  end

  describe "the refusals usage-rules.md names are the ones the code returns" do
    test "get_prices/2 outside US_CRYPTO" do
      assert {:error, {:unsupported_category, "US_STOCK"}} =
               Webull.get_prices(["BTC-USD"],
                 category: "US_STOCK",
                 credentials: credentials(),
                 plug: exploding()
               )
    end

    test "the event tape, the event top of book and the event book are not the contract's" do
      opts = [category: "US_EVENT", credentials: credentials(), plug: exploding()]

      assert {:error, {:use_get_event_trades, "US_EVENT"}} =
               Webull.get_trades("KXGDP-26-T3", opts)

      assert {:error, {:use_get_event_order_book, "US_EVENT"}} =
               Webull.get_top_of_book("KXGDP-26-T3", opts)

      assert {:error, {:unsupported_book_category, "US_EVENT"}} =
               Webull.get_order_book("KXGDP-26-T3", opts)
    end

    test "the volume profile's category, width, session and count" do
      base = [credentials: credentials(), plug: exploding()]

      assert {:error, {:unsupported_footprint_category, "US_ETF"}} =
               Webull.get_volume_profile("AAPL", "1m", [category: "US_ETF"] ++ base)

      assert {:error, {:unsupported_timeframe, "2h"}} =
               Webull.get_volume_profile("AAPL", "2h", base)

      assert {:error, {:unsupported_session, "OVN"}} =
               Webull.get_volume_profile("AAPL", "1m", [session: "OVN"] ++ base)

      assert {:error, {:limit_out_of_range, 1_201, max: 1_200}} =
               Webull.get_volume_profile("AAPL", "1m", [count: 1_201] ++ base)
    end

    test "option bars take no range" do
      assert {:error, {:unsupported_bar_range, :option}} =
               Webull.get_historical_prices(
                 "AAPL260522C00300000",
                 "1d",
                 [start: ~U[2026-01-01 00:00:00Z]],
                 category: "US_OPTION",
                 credentials: credentials(),
                 plug: exploding()
               )
    end

    test "an instrument type with no order matrix" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: "1",
        price: "1",
        instrument_type: :bond
      }

      assert {:error, {:unsupported_instrument_type, :bond}} =
               Webull.place_order(credentials(), request,
                 account_id: "ACCT",
                 plug: exploding()
               )
    end

    test "a statement kind that is not one, and a calendar kind that is not one" do
      assert {:error, {:unsupported_statement_kind, :company_profile}} =
               Webull.get_financials("AAPL", :company_profile,
                 credentials: credentials(),
                 plug: exploding()
               )

      assert {:error, {:unsupported_event_kind, :split}} =
               Webull.get_corporate_events(
                 symbol: "AAPL",
                 kind: :split,
                 credentials: credentials(),
                 plug: exploding()
               )
    end

    test "a token, a client id and a watchlist id or name that cannot be sent" do
      assert {:error, {:invalid_field, :token}} =
               Webull.check_token(nil, credentials: credentials(), plug: exploding())

      assert {:error, {:invalid_field, :client_id}} = Webull.oauth_token(nil, "secret")

      assert {:error, {:invalid_watchlist_id, ""}} =
               Webull.get_watchlist("", credentials: credentials(), plug: exploding())

      assert {:error, {:invalid_watchlist_name, 123}} =
               Webull.create_watchlist(123, ["AAPL"],
                 credentials: credentials(),
                 plug: exploding()
               )
    end
  end

  describe "a news item's publish_time is bounded like every other venue time" do
    defp news(publish_time) do
      body = %{
        "symbol" => "TSLA",
        "data" => [%{"news_id" => "n-1", "publish_time" => publish_time}]
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      Rest.get_news(credentials(), symbols: ["TSLA"], plug: plug, retry_attempts: 0)
    end

    test "a time that is read is still read" do
      assert {:ok, [item]} = news("2026-10-08T09:30:00.000-04:00")
      assert DateTime.compare(item.published_at, ~U[2026-10-08 13:30:00.000Z]) == :eq
    end

    test "text of 64 bytes is carried as written and 65 is a 32-byte copy" do
      at_the_bound = String.duplicate("x", 64)
      assert {:error, {:unparseable_venue_timestamp, ^at_the_bound}} = news(at_the_bound)

      assert {:error, {:unparseable_venue_timestamp, echoed}} = news(String.duplicate("x", 65))
      assert echoed == String.duplicate("x", 32)
    end

    test "a time written in thousands of bytes is refused with a 32-byte copy of it" do
      long = String.duplicate("9", 10_000)

      assert {:error, {:unparseable_venue_timestamp, echoed}} = news(long)
      assert byte_size(echoed) == 32
    end

    test "a value that is not text is described, not copied whole" do
      assert {:error, {:unparseable_venue_timestamp, echoed}} =
               news(%{"a" => String.duplicate("z", 10_000)})

      assert is_binary(echoed)
      assert byte_size(echoed) < 100
    end
  end
end
