defmodule DpExchange.WebullTest do
  use ExUnit.Case, async: false

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Supervisor}

  @moduletag :capture_log

  @credentials %{app_key: "k", app_secret: "s"}

  describe "the declaration" do
    test "names every callback exactly once" do
      declared = Webull.capabilities().endpoints |> Map.keys() |> Enum.sort()

      assert declared == Enum.sort(Venue.behaviour_info(:callbacks))
    end

    test "an endpoint declared :unsupported actually returns the atom" do
      for {{name, arity}, :unsupported} <- Webull.capabilities().endpoints do
        assert apply(Webull, name, unsupported_args(name, arity)) == {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but did not say so"
      end
    end

    test "the FAKE says the same thing, for every declared-unsupported endpoint" do
      # The facade sweep above proves the real module agrees with its declaration. This
      # proves the fake does too — and it matters more than it looks: a consumer's test
      # suite runs against the fake, so a fake that answered differently would let a
      # consumer write a passing test against behaviour the real package does not have.
      #
      # It also keeps the stubs honest. Thirty-three callbacks arrived with Core 0.1.16 and
      # are declared, not implemented; without this they are uncovered lines that nothing
      # would notice going wrong.
      for {{name, arity}, :unsupported} <- Webull.capabilities().endpoints do
        assert apply(Webull.Fake, name, unsupported_args(name, arity)) ==
                 {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but the fake did not say so"
      end
    end

    test "credentials are REQUIRED, which no other venue in this family declares" do
      # Every OpenAPI call is signed, including the ones that look public. A consumer
      # branching on this learns it before calling; one that assumed market data is free
      # learns it from a 401.
      assert Webull.capabilities().credential_benefit == :required
    end

    test "no trade volume is reported, so volume work can be routed elsewhere" do
      refute Webull.capabilities().reports_trade_volume
    end

    test "declares no timeframe the venue does not serve" do
      # `1w` is served and deliberately excluded: its boundary depends on the venue's week
      # start, which nothing here can verify.
      for absent <- ~w(12h 1w 3d),
          do: refute(absent in Webull.capabilities().historical_timeframes)
    end

    test "provenance separates what was measured here from what was inherited" do
      caps = Webull.capabilities()

      assert caps.measured_at == ~D[2026-08-28]
      assert caps.measured_against =~ "verified live"
      assert caps.measured_against =~ "NOT re-measured"
    end

    test "the declaration survives Capabilities' own validation" do
      assert %Capabilities{} = Webull.capabilities()
    end
  end

  describe "identity" do
    test "provider is the atom, everywhere" do
      assert Webull.runtime_id() == :webull
      assert Webull.provider_name() == "Webull"
      # The order builder serves all five of the venue's instrument types, so the
      # declaration says so. It follows the code rather than leading it.
      assert Webull.asset_classes() == [:crypto, :equity]
      assert Webull.market_status([]) == {:ok, :open}
    end

    test "quotes/0 reports the venue's settlement currencies" do
      assert "USD" in Webull.quotes()
    end
  end

  describe "streaming?/1 lets a caller ask before it commits" do
    test "production streams, UAT does not" do
      assert Webull.streaming?(environment: :production)
      refute Webull.streaming?(environment: :uat)
    end

    test "the default is production" do
      assert Webull.streaming?([])
    end
  end

  describe "coverage/1" do
    test "an unstarted feed reports an empty map, not a crash" do
      assert Webull.coverage(feed: :no_such_feed_process) == %{}
    end
  end

  describe "the supervision tree" do
    test "starts a limiter and a feed, and no socket" do
      unique = System.unique_integer([:positive])
      opts = [name: :"sup_#{unique}", feed: :"feed_#{unique}", limiter: :"lim_#{unique}"]

      assert {:ok, pid} = Webull.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      assert length(Elixir.Supervisor.which_children(pid)) == 2
      assert Webull.coverage(feed: opts[:feed]) == %{}
    end

    test "production and UAT derive different names, so both can run at once" do
      # And more importantly they do not share a rate-limit bucket: UAT traffic metering
      # against the production budget would throttle a real order with nothing pointing
      # at the cause.
      refute Supervisor.limiter_name(environment: :production) ==
               Supervisor.limiter_name(environment: :uat)

      refute Supervisor.feed_name(environment: :production) ==
               Supervisor.feed_name(environment: :uat)

      refute Supervisor.supervisor_name(environment: :production) ==
               Supervisor.supervisor_name(environment: :uat)
    end

    test "explicit names still win" do
      assert Supervisor.limiter_name(environment: :uat, limiter: :mine) == :mine
      assert Supervisor.feed_name(environment: :uat, feed: :mine) == :mine
      assert Supervisor.supervisor_name(environment: :uat, name: :mine) == :mine
    end

    test "child_spec/1 takes its id from the name" do
      assert %{id: :custom} = Webull.child_spec(name: :custom)
      assert %{id: DpExchange.Webull} = Webull.child_spec([])
    end
  end

  describe "the fake models what makes this venue different" do
    test "market data without credentials is refused, as the real venue refuses it" do
      # A fake that answered anyway would let a consumer's test pass while the real call
      # returns 401.
      assert Fake.get_price("BTC-USD") == {:refused, :missing_credentials}
      assert Fake.get_symbols() == {:refused, :missing_credentials}
      assert Fake.get_historical_prices("BTC-USD", "1m") == {:refused, :missing_credentials}
    end

    test "with credentials it answers" do
      assert {:ok, _quote} = Fake.get_price("BTC-USD", credentials: @credentials)
      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)

      assert {:ok, [_bar]} =
               Fake.get_historical_prices("BTC-USD", "1m", [], credentials: @credentials)
    end

    test "volume is nil everywhere, never zero" do
      assert {:ok, quote_struct} = Fake.get_price("BTC-USD", credentials: @credentials)
      assert quote_struct.volume == nil

      assert {:ok, [bar]} =
               Fake.get_historical_prices("BTC-USD", "1m", [], credentials: @credentials)

      assert bar.volume == nil
    end

    test "an unlisted symbol is a refusal, and an unserved width an error" do
      assert Fake.get_price("NOPE-USD", credentials: @credentials) == {:refused, :not_listed}

      assert {:error, {:unsupported_timeframe, "1w"}} =
               Fake.get_historical_prices("BTC-USD", "1w", [], credentials: @credentials)

      assert {:refused, :not_listed} =
               Fake.get_historical_prices("NOPE-USD", "1m", [], credentials: @credentials)
    end

    test "UAT refuses to stream, exactly as the real feed does" do
      assert {:error, {:streaming_unavailable, :uat}} =
               Fake.subscribe(["BTC-USD"], environment: :uat)
    end

    test "subscribing in production delivers and reports coverage" do
      assert :ok = Fake.subscribe(["BTC-USD"], to: self())
      assert_receive {:dp_exchange, :webull, %DpExchange.Core.Types.Quote{symbol: "BTC-USD"}}
      assert Fake.coverage() == %{"BTC-USD" => :stream}

      assert :ok = Fake.unsubscribe(["BTC-USD"])
      assert Fake.coverage() == %{}
    end

    test "update_symbols narrows coverage, and notices reach a subscriber" do
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      :ok = Fake.update_symbols(["BTC-USD"])
      assert Fake.coverage() == %{"BTC-USD" => :stream}

      :ok = Fake.subscribe_notices(to: self())
      assert_receive {:dp_exchange, :webull, %DpExchange.Core.Notice{kind: :link_up}}
    end

    test "a range outside the fake's single bar filters it out" do
      future = ~U[2027-01-01 00:00:00Z]

      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1m", [start: future],
                 credentials: @credentials
               )
    end

    test "it declares the real venue's capabilities and starts nothing" do
      assert Fake.capabilities() == Webull.capabilities()
      assert Fake.start_link([]) == :ignore
      assert %{id: :fake} = Fake.child_spec(name: :fake)
      assert Fake.market_status([]) == {:ok, :open}
      assert Fake.provider_name() == "Webull"
      assert Fake.runtime_id() == :webull
      assert Fake.asset_classes() == [:crypto, :equity]
    end
  end

  describe "the facade's short forms, which reach no network without credentials" do
    test "market data refuses before a request is made" do
      # `credentials/1` defaults to an empty map, `Auth` refuses it, and nothing is sent.
      # That is why these are safe to call with no options at all.
      assert Webull.get_price("BTC-USD") == {:error, {:missing_credentials, :webull}}
      assert Webull.get_symbols() == {:error, {:missing_credentials, :webull}}

      assert Webull.get_historical_prices("BTC-USD", "1m") ==
               {:error, {:missing_credentials, :webull}}
    end

    test "coverage/0 answers for an unstarted default feed" do
      assert Webull.coverage() == %{}
    end

    test "coverage accepts a pid as well as a name" do
      unique = System.unique_integer([:positive])
      {:ok, feed} = DpExchange.Webull.Feed.start_link(name: :"pid_feed_#{unique}", socket: self())

      assert Webull.coverage(feed: feed) == %{}
    end
  end

  describe "the fake's unsupported surface" do
    test "everything the real package does not implement says so here too" do
      # Less capable is allowed; differently capable is not. A fake that answered where the
      # real package refuses would let a consumer build on something that does not exist.
      # get_order_book/2 is implemented for equities now. A crypto pair is still refused —
      # this venue publishes no crypto depth — which is a different answer from "not
      # implemented" and is asserted in the order book tests.
      assert Fake.get_market_overview([]) == {:error, :not_supported}
      assert Fake.list_instruments([]) == {:error, :not_supported}
      # get_balances/2, get_accounts/2 and get_positions/1 are implemented now.
      # get_balances and get_positions refuse without an `account_id`, which is the venue's
      # requirement rather than a missing implementation; get_accounts takes none.
      assert Fake.get_fees(@credentials, []) == {:error, :not_supported}
      # get_transfers/2 is implemented now. It refuses without an account_id, which is the
      # venue's requirement rather than a missing implementation.
      # place_order is implemented now, so it no longer belongs in this sweep. It refuses
      # for its own reason — the venue requires an account on every order and this package
      # will not choose one — which is a different answer from "not implemented" and is
      # asserted in the order tests.
      # cancel_order, get_order and get_orders are implemented now. They refuse without an
      # account_id, which is the venue's requirement rather than a missing implementation,
      # and is asserted in the order tests.
      assert Fake.get_trade_history(@credentials, []) == {:error, :not_supported}
      assert Fake.test_connection(@credentials, []) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(@credentials, []) == {:error, :not_supported}
      assert Fake.quantization("BTC-USD") == {:error, :not_supported}
    end

    test "subscribing to only an unlisted symbol pushes nothing" do
      assert :ok = Fake.subscribe(["NOPE-USD"], to: self())

      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :webull, _anything}, 50
    end

    test "a bar before the range end is kept" do
      assert {:ok, [_bar]} =
               Fake.get_historical_prices("BTC-USD", "1m", [end: ~U[2027-01-01 00:00:00Z]],
                 credentials: @credentials
               )
    end
  end

  # Argument shapes for the declared-unsupported sweep. A lookup rather than a case, so a
  # callback added to the facade adds a row instead of a branch.
  @wide_facade_args %{
    {:withdraw, 5} => ["BTC", "bitcoin", :one, "addr", []],
    {:estimate_withdrawal_fee, 4} => ["BTC", "bitcoin", :one, []],
    {:quote_conversion, 4} => ["BTC", "USD", :one, []],
    {:get_deposit_address, 3} => ["BTC", "bitcoin", []],
    {:create_watchlist, 3} => ["name", [], []],
    {:get_financials, 3} => ["BTC-USD", :balance_sheet, []],
    {:rename_account, 3} => ["id", "name", []],
    {:stake, 3} => ["BTC", :one, []],
    {:unstake, 3} => ["BTC", :one, []],
    {:get_funding, 2} => ["BTC-USD", []],
    {:get_contract_stats, 2} => ["BTC-USD", []],
    {:get_option_chain, 2} => ["BTC-USD", []],
    {:get_option_expirations, 2} => ["BTC-USD", []],
    {:get_option_greeks, 2} => ["id", []],
    {:get_watchlist, 2} => ["id", []],
    {:update_watchlist, 2} => ["id", []],
    {:delete_watchlist, 2} => ["id", []],
    {:get_filings, 2} => ["id", []],
    {:get_screener, 2} => ["id", []],
    {:commit_conversion, 2} => ["id", []],
    {:get_conversion, 2} => ["id", []],
    {:get_top_of_book, 2} => ["BTC-USD", []]
  }

  defp unsupported_args(name, arity) do
    case Map.fetch(@wide_facade_args, {name, arity}) do
      {:ok, args} ->
        Enum.map(args, fn
          :one -> Decimal.new("1")
          other -> other
        end)

      :error ->
        legacy_args(name, arity)
    end
  end

  defp legacy_args(name, arity) do
    case {name, arity} do
      {:quantization, 1} -> ["BTC-USD"]
      {:list_instruments, 1} -> [[]]
      {:get_market_overview, 1} -> [[]]
      {:get_order_book, 2} -> ["BTC-USD", []]
      {:place_order, 3} -> [@credentials, %{}, []]
      # Any arity-4 callback here takes credentials, an id, a change map and opts.
      {_name, 4} -> [@credentials, "id", %{}, []]
      {_name, 3} -> [@credentials, "id", []]
      {_name, 2} -> [@credentials, []]
      {_name, 1} -> [[]]
    end
  end
end
