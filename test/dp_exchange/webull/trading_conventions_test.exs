defmodule DpExchange.Webull.TradingConventionsTest do
  @moduledoc """
  The family's trading conventions (T1-T12), applied to `place_order/3`, `preview_order/3`,
  `replace_order/4`, `cancel_order/3` and `get_order/3`, in `Rest` AND `Fake`: the same answer
  in the same order, so a caller can never retry its way into a duplicate order or get a
  different order than it asked for.

  Each test says what the old behaviour was.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.{Fake, Rest}

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

  # Refuses every request the way a full bucket does: no token now, 5 seconds to wait.
  defmodule FullLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 5_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # A limiter that cannot answer at all (its process is down, say).
  defmodule DownLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "key", app_secret: "secret"}
  @account "93IUJ28O9VO2KBGHDHR4H9"

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp responding(body, status) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp equity(overrides \\ %{}) do
    Map.merge(
      %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("10")
      },
      overrides
    )
  end

  defp batch_entry(overrides) do
    Map.merge(
      %{
        instrument_type: :equity,
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("1"),
        price: Decimal.new("10"),
        support_trading_session: :core
      },
      overrides
    )
  end

  # The real call, with `extra` taking precedence over the defaults.
  defp place(request, extra \\ [], credentials \\ @credentials) do
    Rest.place_order(
      credentials,
      request,
      Keyword.merge([account_id: @account, plug: exploding(), retry_attempts: 0], extra)
    )
  end

  defp fake_place(request, opts \\ [account_id: @account], credentials \\ @credentials) do
    Fake.place_order(credentials, request, opts)
  end

  defp uniq, do: System.unique_integer([:positive])

  describe "T1: only an outcome that may have been sent is order_unconfirmed" do
    test "missing or blank credentials are the plain error, in Rest and in the Fake" do
      for credentials <- [%{}, nil, %{app_key: "k", app_secret: "   "}] do
        assert {:error, {:missing_credentials, :webull}} =
                 place(equity(%{client_order_id: "mine-1"}), [], credentials)

        assert {:error, {:missing_credentials, :webull}} =
                 Fake.place_order(credentials, equity(%{client_order_id: "mine-1"}),
                   account_id: @account
                 )
      end
    end

    test "our own rate limiter refusing is the plain error, with nothing sent" do
      Config.put_override(:rate_limit_module, FullLimiter)

      assert {:error, {:exchange_error, :webull, "Throttled by our own rate limiter" <> _rest}} =
               place(equity(%{client_order_id: "mine-1"}))
    end

    test "a limiter that cannot answer is the plain error, with nothing sent" do
      Config.put_override(:rate_limit_module, DownLimiter)

      assert {:error, {:exchange_error, :webull, "Rate limiter unavailable"}} =
               place(equity(%{client_order_id: "mine-1"}))
    end

    test "a transport failure after the send carries the id that was sent" do
      timing_out = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, {:order_unconfirmed, "mine-1", _reason}} =
               place(equity(%{client_order_id: "mine-1"}), plug: timing_out)
    end

    test "a 5xx carries the id, and a generated one is the one that was sent" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent_raw, raw})
        responding(%{"msg" => "down"}, 503).(conn)
      end

      assert {:error, {:order_unconfirmed, id, _reason}} = place(equity(), plug: plug)
      assert is_binary(id) and String.length(id) == 32

      assert_receive {:sent_raw, raw}, 5_000
      assert %{"new_orders" => [%{"client_order_id" => ^id}]} = Jason.decode!(raw)
    end

    test "a 2xx that is not JSON is unconfirmed too" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "<html>ok</html>") end

      assert {:error, {:order_unconfirmed, "mine-1", _reason}} =
               place(equity(%{client_order_id: "mine-1"}), plug: plug)
    end

    test "a replace that may have landed carries the order id; one never sent does not" do
      timing_out = fn conn -> Req.Test.transport_error(conn, :timeout) end
      edit = [instrument_type: :equity, order_type: :limit, account_id: @account]

      assert {:error, {:order_unconfirmed, "abc", _reason}} =
               Rest.replace_order(
                 @credentials,
                 "abc",
                 %{quantity: 2},
                 [plug: timing_out, retry_attempts: 0] ++ edit
               )

      assert {:error, {:missing_credentials, :webull}} =
               Rest.replace_order(
                 %{},
                 "abc",
                 %{quantity: 2},
                 [plug: exploding(), retry_attempts: 0] ++ edit
               )
    end

    test "retry_attempts: 3 still sends place, replace and a watchlist write once" do
      # Every write is sent once whatever the caller passes (`send_once/1`): a timeout after
      # that one send is unconfirmed for place, replace and a watchlist write alike, and the
      # plug sees exactly one request per call. The limiter (the setup's permissive one)
      # grants every call.
      counter = :counters.new(1, [])

      timing_out = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.transport_error(conn, :timeout)
      end

      retrying = [retry_attempts: 3, retry_delay: 1]

      assert {:error, {:order_unconfirmed, "mine-1", _reason}} =
               place(equity(%{client_order_id: "mine-1"}), [plug: timing_out] ++ retrying)

      assert :counters.get(counter, 1) == 1

      assert {:error, {:order_unconfirmed, "abc", _reason}} =
               Rest.replace_order(
                 @credentials,
                 "abc",
                 %{quantity: 2},
                 [plug: timing_out, account_id: @account, instrument_type: :equity] ++
                   [order_type: :limit] ++ retrying
               )

      assert :counters.get(counter, 1) == 2

      assert {:error, {:write_unconfirmed, nil, _reason}} =
               Rest.delete_watchlist("wl-1", @credentials, [plug: timing_out] ++ retrying)

      assert :counters.get(counter, 1) == 3

      throttled = {:exchange_error, :webull, "Throttled by our own rate limiter (x)"}
      assert Rest.unsent?(throttled, retry_attempts: 1)
      assert Rest.unsent?(throttled, retry_attempts: 0)
      assert Rest.unsent?(throttled, [])
      refute Rest.unsent?(throttled, retry_attempts: 3)
      refute Rest.unsent?(:rate_limit_timeout, retry_attempts: 3)
      refute Rest.unsent?("Rate limiter unavailable", retry_attempts: nil)
      assert Rest.unsent?({:missing_credentials, :webull}, retry_attempts: 3)
    end

    test "a batch that may have been placed carries every id; one never sent does not" do
      timing_out = fn conn -> Req.Test.transport_error(conn, :timeout) end
      batch = [batch_entry(%{client_order_id: "b-1"}), batch_entry(%{symbol: "MSFT"})]

      assert {:error, {:order_unconfirmed, ["b-1", generated], _reason}} =
               Rest.place_orders(@credentials, batch,
                 account_id: @account,
                 plug: timing_out,
                 retry_attempts: 0
               )

      assert is_binary(generated) and String.length(generated) == 32

      # A 2xx that holds no row at all is as unproven as a timeout.
      assert {:error, {:order_unconfirmed, ["b-1"], :unexpected_response_shape}} =
               Rest.place_orders(@credentials, [batch_entry(%{client_order_id: "b-1"})],
                 account_id: @account,
                 plug: responding([], 200),
                 retry_attempts: 0
               )

      assert {:error, {:missing_credentials, :webull}} =
               Rest.place_orders(%{}, batch,
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )

      Config.put_override(:rate_limit_module, FullLimiter)

      assert {:error, {:exchange_error, :webull, "Throttled by our own rate limiter" <> _rest}} =
               Rest.place_orders(@credentials, batch,
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )
    end

    test "Rest.unsent?/1 names exactly the decided-before-sending reasons" do
      assert Rest.unsent?({:missing_credentials, :webull})
      assert Rest.unsent?({:exchange_error, :webull, "Throttled by our own rate limiter (x)"})
      assert Rest.unsent?("Rate limiter unavailable")
      refute Rest.unsent?({:exchange_error, :webull, "HTTP 503: nope"})
      refute Rest.unsent?("Request failed: timeout")
      refute Rest.unsent?(:timeout)
    end
  end

  describe "T2/T3/T4/T5/T7: one validator, one order, shared by Rest and the Fake" do
    # Each request is faulty in the ways listed; the FIRST in the family order is the answer:
    # request is a map, unknown keys, symbol, side, order type, duration, size, price fields,
    # client order id. Rest (nothing is ever sent) and the Fake must agree on every one.
    @too_long String.duplicate("a", 33)
    @ordered [
      {%{post_only: true, symbol: nil}, {:unsupported_order_field, :post_only}},
      {%{reduce_only: true}, {:unsupported_order_field, :reduce_only}},
      {%{end_time: 1}, {:unsupported_order_field, :end_time}},
      {%{symbol: nil, side: nil}, {:invalid_symbol, nil}},
      {%{symbol: "   ", side: nil}, {:invalid_symbol, "   "}},
      {%{side: :short, order_type: nil}, {:invalid_side, :short}},
      {%{side: nil, order_type: nil}, {:missing_field, :side}},
      {%{order_type: nil, time_in_force: nil, quantity: nil}, {:missing_field, :order_type}},
      {%{order_type: :bogus, time_in_force: nil}, {:unsupported_order_type, :bogus}},
      {%{time_in_force: nil, quantity: nil}, {:missing_field, :time_in_force}},
      {%{time_in_force: :ioc, quantity: nil}, {:unsupported_order_combination, :limit, :ioc}},
      # DV10: the expiry is the time-in-force step's, ahead of the size and every price.
      {%{instrument_type: :event, time_in_force: :gtd, quantity: nil, price: 0},
       {:missing_field, :expire_date}},
      {%{expire_date: "2026-12-01", quantity: 0}, {:unexpected_field, :expire_date}},
      # DV4: sizing answers are tagged tuples naming the field, never bare atoms.
      {%{amount: Decimal.new("5")}, {:unexpected_field, :amount}},
      {%{
         quantity: nil,
         amount: Decimal.new("5"),
         order_type: :stop_limit,
         stop_price: Decimal.new("9")
       }, {:unexpected_field, :amount}},
      {%{quantity: 0, price: 0}, {:invalid_quantity, 0}},
      {%{quantity: 1.5}, {:invalid_quantity, 1.5}},
      {%{quantity: nil, price: 0}, {:missing_field, :quantity}},
      {%{stop_price: Decimal.new("1"), price: 0}, {:unexpected_field, :stop_price}},
      {%{trailing_stop_step: Decimal.new("1")}, {:unexpected_field, :trailing_stop_step}},
      {%{price: nil, client_order_id: @too_long}, {:missing_field, :price}},
      {%{price: 10.5}, {:invalid_price, 10.5}},
      {%{price: 0, client_order_id: ""}, {:invalid_price, 0}},
      {%{client_order_id: @too_long}, {:invalid_client_order_id, @too_long}},
      {%{client_order_id: "  "}, {:invalid_client_order_id, "  "}}
    ]

    test "every faulty request is refused in the same order by Rest, preview and the Fake" do
      for {overrides, expected} <- @ordered do
        request = equity(overrides)
        refusal = {:error, expected}

        assert refusal == Rest.validate_order_request(request), inspect(overrides)
        assert refusal == place(request), inspect(overrides)
        assert refusal == Fake.place_order(@credentials, request, account_id: @account)

        assert refusal ==
                 Rest.preview_order(@credentials, request,
                   account_id: @account,
                   plug: exploding(),
                   retry_attempts: 0
                 )

        assert refusal == Fake.preview_order(@credentials, request, account_id: @account)
      end
    end

    test "the account option comes after the request and before the credentials" do
      assert {:error, {:missing_option, :account_id}} =
               Rest.place_order(%{}, equity(), plug: exploding(), retry_attempts: 0)

      assert {:error, {:missing_option, :account_id}} = Fake.place_order(%{}, equity(), [])

      # A bad request is still the bad request when the account is missing too.
      assert {:error, {:invalid_symbol, nil}} =
               Rest.place_order(%{}, equity(%{symbol: nil}), plug: exploding())

      assert {:error, {:missing_credentials, :webull}} = place(equity(), [], %{})

      assert {:error, {:missing_credentials, :webull}} =
               fake_place(equity(), [account_id: @account], %{})
    end

    test "a request that is not a map is a named refusal, never a BadMapError" do
      for bad <- [nil, [symbol: "AAPL"], "AAPL", 5, :market] do
        expected = {:error, {:invalid_order_request, bad}}

        assert expected == place(bad)
        assert expected == Rest.validate_order_request(bad)
        assert expected == Fake.place_order(@credentials, bad, account_id: @account)

        assert expected ==
                 Rest.preview_order(@credentials, bad,
                   account_id: @account,
                   plug: exploding(),
                   retry_attempts: 0
                 )

        assert expected == Fake.preview_order(@credentials, bad, account_id: @account)
      end
    end

    test "a valid crypto preview is refused as unsupported; an invalid one gets place's tuple" do
      valid = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("1"),
        price: Decimal.new("1")
      }

      assert {:error, {:preview_not_supported, :crypto}} =
               Rest.preview_order(@credentials, valid,
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )

      # The request is judged as `place_order/3` judges it first (Core group 50), so a crypto
      # request place refuses is refused with place's tuple, not as "unsupported".
      invalid = %{symbol: "BTC-USD"}

      assert {:error, {:missing_field, :side}} = place(invalid)

      assert {:error, {:missing_field, :side}} =
               Rest.preview_order(@credentials, invalid,
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:missing_field, :side}} =
               Fake.preview_order(@credentials, invalid, account_id: @account)
    end

    test "replace_order/4 refuses an empty or non-map change map before any option is asked" do
      for bad <- [%{}, nil, "price", [price: "1"]] do
        expected = {:error, {:invalid_order_request, bad}}

        assert expected == Rest.replace_order(@credentials, "abc", bad, account_id: @account)
        assert expected == Fake.replace_order(@credentials, "abc", bad, account_id: @account)
      end
    end

    test "replace_order/4 judges a present nil as place_order/3 judges that field" do
      # `Core.Venue.replace_order/4`: "a present `nil` included, so `%{price: nil}` is
      # `{:invalid_price, nil}`, not 'no change'".
      opts = [account_id: @account, instrument_type: :equity, order_type: :limit]

      for {changes, expected} <- [
            {%{price: nil}, {:invalid_price, nil}},
            {%{quantity: nil}, {:invalid_quantity, nil}},
            {%{order_type: nil}, {:missing_field, :order_type}},
            {%{time_in_force: nil}, {:missing_field, :time_in_force}},
            {%{price: nil, quantity: nil}, {:invalid_quantity, nil}}
          ] do
        assert {:error, expected} == Rest.replace_order(@credentials, "abc", changes, opts)
        assert {:error, expected} == Fake.replace_order(@credentials, "abc", changes, opts)
      end
    end

    test "buy and sell are accepted as atoms or text in any case; short is not" do
      for side <- [:buy, :sell, "buy", "SELL", "Buy"] do
        assert :ok == Rest.validate_order_request(equity(%{side: side}))
      end

      for side <- [:short, "short", "SHORT", :bid, "", 1] do
        assert {:error, {:invalid_side, ^side}} =
                 Rest.validate_order_request(equity(%{side: side}))
      end
    end

    test "a Decimal, an integer and a numeric string are exact and accepted; a float is not" do
      for number <- [Decimal.new("1.5"), 2, "0.25"] do
        assert :ok == Rest.validate_order_request(equity(%{quantity: number, price: number}))
      end
    end

    test "no order type and no duration is inferred, for every instrument" do
      for instrument <- [:crypto, :equity, :option, :futures, :event] do
        request = equity(%{instrument_type: instrument})

        assert {:error, {:missing_field, :order_type}} =
                 Rest.validate_order_request(Map.delete(request, :order_type))

        assert {:error, {:missing_field, :time_in_force}} =
                 Rest.validate_order_request(Map.delete(request, :time_in_force))
      end
    end

    test "a market order with no duration names the duration, not an unnamed pair" do
      request = equity(%{order_type: :market}) |> Map.delete(:time_in_force) |> Map.delete(:price)

      assert {:error, {:missing_field, :time_in_force}} = Rest.validate_order_request(request)
      assert {:error, {:missing_field, :time_in_force}} = place(request)
    end

    test "a GTD order needs its expiry; any other duration refuses one" do
      gtd = equity(%{instrument_type: :event, time_in_force: :gtd})

      assert {:error, {:missing_field, :expire_date}} = Rest.validate_order_request(gtd)

      assert {:error, {:missing_field, :expire_date}} =
               Fake.place_order(@credentials, gtd, account_id: @account)

      assert :ok == Rest.validate_order_request(Map.put(gtd, :expire_date, "2026-12-01"))

      day = equity(%{expire_date: "2026-12-01"})
      assert {:error, {:unexpected_field, :expire_date}} = Rest.validate_order_request(day)
      assert {:error, {:unexpected_field, :expire_date}} = fake_place(day)
    end

    test "the order the Fake hands back is the normalised one, not the caller's spelling" do
      request = equity(%{side: "SELL", quantity: 3, client_order_id: "norm-#{uniq()}"})

      assert {:ok, order} = Fake.place_order(@credentials, request, account_id: @account)
      assert order.side == :sell
      assert Decimal.equal?(order.quantity, Decimal.new(3))
    end
  end

  describe "T14: the Fake answers a reused client_order_id as a refusal, not an overwrite" do
    test "the second placement is refused and the first order is untouched" do
      id = "dup-#{uniq()}"
      opts = [account_id: @account]

      assert {:ok, %{id: ^id}} =
               Fake.place_order(@credentials, equity(%{client_order_id: id}), opts)

      assert {:refused, {:duplicate_client_order_id, ^id}} =
               Fake.place_order(
                 @credentials,
                 equity(%{client_order_id: id, quantity: Decimal.new("99")}),
                 opts
               )

      assert {:ok, read} = Fake.get_order(@credentials, id, opts)
      assert Decimal.equal?(read.quantity, Decimal.new("1"))
    end

    test "ids the Fake generates are unique per placement" do
      opts = [account_id: @account]
      assert {:ok, first} = Fake.place_order(@credentials, equity(), opts)
      assert {:ok, second} = Fake.place_order(@credentials, equity(), opts)
      refute first.id == second.id
    end

    test "a refused duplicate is checked after the request, account and credentials" do
      id = "dup-#{uniq()}"
      request = equity(%{client_order_id: id})
      assert {:ok, _order} = fake_place(request)

      assert {:error, {:invalid_symbol, nil}} = fake_place(%{request | symbol: nil})
      assert {:error, {:missing_option, :account_id}} = fake_place(request, [])

      assert {:error, {:missing_credentials, :webull}} =
               fake_place(request, [account_id: @account], %{})
    end
  end

  describe "T8: order ids" do
    test "nil, non-text and blank are {:invalid_order_id, v}, before account and credentials" do
      for id <- [nil, "", "   ", 7, :abc, ["x"]] do
        expected = {:error, {:invalid_order_id, id}}

        # No account and no credentials at all: the id is what is wrong first.
        assert expected == Rest.get_order(%{}, id, plug: exploding())
        assert expected == Rest.cancel_order(%{}, id, plug: exploding())
        assert expected == Rest.replace_order(%{}, id, %{quantity: 1}, plug: exploding())
        assert expected == Fake.get_order(%{}, id, [])
        assert expected == Fake.cancel_order(%{}, id, [])
        assert expected == Fake.replace_order(%{}, id, %{quantity: 1}, [])
      end
    end

    test "a whitespace-only id is refused even with an account and credentials" do
      assert {:error, {:invalid_order_id, "  "}} =
               Rest.cancel_order(@credentials, "  ",
                 account_id: @account,
                 plug: exploding(),
                 retry_attempts: 0
               )
    end
  end

  describe "T9: a 404 is a permanent refusal, not a retryable exchange_error" do
    test "reads, cancels and placements" do
      opts = [account_id: @account, plug: responding(%{}, 404), retry_attempts: 0]

      assert {:refused, :not_found} = Rest.get_order(@credentials, "abc", opts)
      assert {:refused, :not_found} = Rest.cancel_order(@credentials, "abc", opts)
      assert {:refused, :not_found} = Rest.place_order(@credentials, equity(), opts)
    end

    test "the Fake answers the same for an id it never issued" do
      opts = [account_id: @account]
      never = "never-#{uniq()}"

      assert {:refused, :not_found} = Fake.get_order(@credentials, never, opts)
      assert {:refused, :not_found} = Fake.cancel_order(@credentials, never, opts)
    end
  end

  describe "M6: replace_order never guesses which order is being edited" do
    @changes %{price: Decimal.new("11")}

    test "both options are required, and their absence is named" do
      base = [account_id: @account, plug: exploding()]

      for call <- [&Rest.replace_order/4, &Fake.replace_order/4] do
        assert {:error, {:missing_option, :instrument_type}} =
                 call.(@credentials, "abc", @changes, [order_type: :limit] ++ base)

        assert {:error, {:missing_option, :order_type}} =
                 call.(@credentials, "abc", @changes, [instrument_type: :equity] ++ base)

        assert {:error, {:missing_option, :instrument_type}} =
                 call.(@credentials, "abc", @changes, base)
      end
    end

    test "the edit table comes from the named order type, not a default" do
      opts = [
        instrument_type: :equity,
        order_type: :market,
        account_id: @account,
        plug: exploding()
      ]

      assert {:error, {:unsupported_order_edit, :market, [:price]}} =
               Rest.replace_order(@credentials, "abc", @changes, opts)

      assert {:error, {:unsupported_order_edit, :market, [:price]}} =
               Fake.replace_order(@credentials, "abc", @changes, opts)
    end

    test "changes that are not a map are {:invalid_order_request, changes}, not a raise" do
      opts = [
        instrument_type: :equity,
        order_type: :limit,
        account_id: @account,
        plug: exploding()
      ]

      for bad <- [nil, [price: 1], "x", 7] do
        expected = {:error, {:invalid_order_request, bad}}
        assert expected == Rest.replace_order(@credentials, "abc", bad, opts)
        assert expected == Fake.replace_order(@credentials, "abc", bad, opts)
      end
    end

    test "an instrument this package cannot build is named, in Rest and in the Fake" do
      opts = [
        instrument_type: :bond,
        order_type: :limit,
        account_id: @account,
        plug: exploding()
      ]

      expected = {:error, {:unsupported_instrument_type, :bond}}
      assert expected == Rest.replace_order(@credentials, "abc", @changes, opts)
      assert expected == Fake.replace_order(@credentials, "abc", @changes, opts)
    end
  end

  describe "event contract AMOUNT sizing is BUY-only and FOK-only (common-order-place.md)" do
    defp event_amount(overrides) do
      Map.merge(
        %{
          instrument_type: :event,
          symbol: "EVT-1",
          side: :buy,
          order_type: :limit,
          time_in_force: :fok,
          amount: Decimal.new("25"),
          price: Decimal.new("0.5"),
          event_outcome: :yes
        },
        overrides
      )
    end

    test "a SELL or a non-FOK duration is refused before the request, by Rest and the Fake" do
      for {overrides, expected} <- [
            {%{side: :sell}, {:invalid_side, :sell}},
            {%{time_in_force: :gtc}, {:unsupported_order_combination, :amount, :gtc}}
          ] do
        request = event_amount(overrides)
        refusal = {:error, expected}

        assert refusal == Rest.validate_order_request(request)
        assert refusal == place(request)
        assert refusal == Fake.place_order(@credentials, request, account_id: @account)
      end
    end

    test "BUY at FOK is accepted, and quantity sizing is not restricted" do
      assert :ok == Rest.validate_order_request(event_amount(%{}))

      sold = event_amount(%{side: :sell, amount: nil, quantity: Decimal.new("3")})
      assert :ok == Rest.validate_order_request(sold)
    end
  end

  describe "cancel_order/3 is sent once whatever the caller passes" do
    test "retry_attempts: 3 on a failing cancel makes exactly one request" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        responding(%{"msg" => "down"}, 503).(conn)
      end

      assert {:error, _reason} =
               Rest.cancel_order(@credentials, "abc",
                 account_id: @account,
                 plug: plug,
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "T13: the facade takes opts \\\\ [] on every order call" do
    test "each order call is callable without options and answers the named refusal" do
      # No account option and no network: the refusal is decided before anything is sent.
      missing_account = {:error, {:missing_option, :account_id}}

      assert missing_account == DpExchange.Webull.place_order(@credentials, equity())
      assert missing_account == DpExchange.Webull.preview_order(@credentials, equity())
      assert missing_account == DpExchange.Webull.cancel_order(@credentials, "abc")
      assert missing_account == DpExchange.Webull.get_order(@credentials, "abc")
      assert missing_account == DpExchange.Webull.get_orders(@credentials)

      # The edit table is named by the caller, never defaulted.
      assert {:error, {:missing_option, :instrument_type}} =
               DpExchange.Webull.replace_order(@credentials, "abc", @changes)
    end
  end

  describe "T12: the account option" do
    test "a missing, blank or non-text account is {:missing_option, :account_id}" do
      for bad <- [nil, "", "   ", 123, false, :acct] do
        assert {:error, {:missing_option, :account_id}} = Rest.validate_account(account_id: bad)
      end

      assert {:error, {:missing_option, :account_id}} = Rest.validate_account([])
      assert {:ok, @account} = Rest.validate_account(account_id: @account)
    end
  end
end
