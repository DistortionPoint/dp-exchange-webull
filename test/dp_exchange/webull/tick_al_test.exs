defmodule DpExchange.Webull.TickALTest do
  @moduledoc """
  Tick AL: how a write reads the venue's HTTP status.

  Core's DV6: a 4xx answered to the only attempt of a write is `{:refused, reason}` (the
  venue read the request and declined it), except 429 (a plain `{:error, reason}`, the venue
  did not look) and, here, 408 (a request timeout does not say whether the server acted). A
  5xx is unconfirmed. This venue documents a business response, `417` with
  `{"error_code": ..., "message": ...}`, which used to come back as `:order_unconfirmed`.
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{app_key: "key", app_secret: "secret"}
  @account "93IUJ28O9VO2KBGHDHR4H9"

  @business %{
    "error_code" => "OPENAPI_NO_NIGHT_TRADING_TIME",
    "message" => "The current period does not support placing night orders"
  }

  # Answers every request with `status` and reports it. The caller drains `{:hit, path}`
  # messages afterwards: the request has completed by then, so no wait is needed.
  defp answering(status, body, headers \\ []) do
    me = self()

    fn conn ->
      send(me, {:hit, conn.request_path})

      headers
      |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_resp_header(acc, key, value) end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp hits(acc \\ 0) do
    receive do
      {:hit, _path} -> hits(acc + 1)
    after
      0 -> acc
    end
  end

  defp request do
    %{
      client_order_id: "abc",
      symbol: "BTC-USD",
      side: :buy,
      quantity: Decimal.new("0.5"),
      price: Decimal.new("40000"),
      order_type: :limit,
      time_in_force: :gtc
    }
  end

  defp batch_entry do
    %{
      instrument_type: :equity,
      symbol: "AAPL",
      side: :buy,
      quantity: Decimal.new("10"),
      price: Decimal.new("190"),
      order_type: :limit,
      time_in_force: :day,
      support_trading_session: :core,
      client_order_id: "b-1"
    }
  end

  defp place(plug) do
    Rest.place_order(@credentials, request(), account_id: @account, plug: plug)
  end

  describe "place_order/3" do
    test "the documented 417 business response is a refusal carrying the error code" do
      assert {:refused, {:venue_error, 417, text}} = place(answering(417, @business))
      assert text == "OPENAPI_NO_NIGHT_TRADING_TIME: " <> @business["message"]
      assert hits() == 1
    end

    test "409, 415, 418 and 422 are refusals too, each sent once" do
      for status <- [409, 415, 418, 422] do
        assert {:refused, {:venue_error, ^status, "no"}} =
                 place(answering(status, %{"message" => "no"})),
               "#{status} was not a refusal"

        assert hits() == 1
      end
    end

    test "a 408 and a 5xx may have reached the venue: the id goes back, nothing is refused" do
      for status <- [408, 500, 502, 503] do
        assert {:error, {:order_unconfirmed, "abc", {:exchange_error, :webull, text}}} =
                 place(answering(status, %{"msg" => "x"})),
               "#{status} was not unconfirmed"

        assert is_binary(text)
        assert hits() == 1
      end
    end

    test "a venue 429 is a plain error carrying the wait: nothing was processed" do
      plug = answering(429, %{"message" => "slow down"}, [{"retry-after", "7"}])

      assert {:error, {:exchange_error, :webull, "Rate limited by the venue" <> rest}} =
               place(plug)

      assert rest =~ "7s"
      assert hits() == 1
    end

    test "a retry_attempts reaching Rest does not turn a 500 into several requests" do
      assert {:error, {:order_unconfirmed, "abc", _reason}} =
               Rest.place_order(@credentials, request(),
                 account_id: @account,
                 plug: answering(500, %{}),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert hits() == 1
    end

    test "unsent?/2 treats the venue 429 as a refusal before the first attempt only" do
      reason = {:exchange_error, :webull, "Rate limited by the venue — retry after 3s"}

      assert Rest.unsent?(reason)
      assert Rest.unsent?(reason, retry_attempts: 1)
      refute Rest.unsent?(reason, retry_attempts: 3)
    end
  end

  describe "the other writes read a 4xx the same way" do
    test "place_orders/3 refuses on a 417" do
      assert {:refused, {:venue_error, 417, _text}} =
               Rest.place_orders(@credentials, [batch_entry()],
                 account_id: @account,
                 plug: answering(417, @business)
               )

      assert hits() == 1
    end

    test "cancel_order/3 refuses on a 422" do
      assert {:refused, {:venue_error, 422, "bad"}} =
               Rest.cancel_order(@credentials, "abc",
                 account_id: @account,
                 plug: answering(422, %{"message" => "bad"})
               )

      assert hits() == 1
    end

    test "replace_order/4 refuses on a 409 and does not read the order back" do
      assert {:refused, {:venue_error, 409, "stale"}} =
               Rest.replace_order(@credentials, "abc", %{quantity: 3},
                 account_id: @account,
                 instrument_type: :equity,
                 order_type: :limit,
                 plug: answering(409, %{"message" => "stale"})
               )

      assert hits() == 1
    end

    test "a watchlist delete refuses on a 409 and is unconfirmed on a 500" do
      assert {:refused, {:venue_error, 409, "busy"}} =
               Rest.delete_watchlist("wl-1", @credentials,
                 plug: answering(409, %{"message" => "busy"})
               )

      assert {:error, {:write_unconfirmed, nil, _reason}} =
               Rest.delete_watchlist("wl-1", @credentials, plug: answering(500, %{}))

      assert hits() == 2
    end

    test "a watchlist write answered by the venue's 429 is a plain error, not unconfirmed" do
      assert {:error, {:exchange_error, :webull, "Rate limited by the venue" <> _rest}} =
               Rest.delete_watchlist("wl-1", @credentials,
                 plug: answering(429, %{}, [{"retry-after", "2"}])
               )

      assert hits() == 1
    end

    test "create_token/2 refuses on a 422" do
      assert {:refused, {:venue_error, 422, "no"}} =
               Rest.create_token(@credentials, plug: answering(422, %{"message" => "no"}))

      assert hits() == 1
    end

    test "oauth_token/3 refuses on a 422 and leaves a 408 an error" do
      assert {:refused, {:venue_error, 422, "bad grant"}} =
               Rest.oauth_token("CLIENT", "secret",
                 code: "c",
                 plug: answering(422, %{"message" => "bad grant"})
               )

      assert {:error, {:exchange_error, :webull, "HTTP 408" <> _rest}} =
               Rest.oauth_token("CLIENT", "secret", code: "c", plug: answering(408, %{}))

      assert hits() == 2
    end
  end

  describe "a trailing stop names what its step measures" do
    defp trailing(overrides) do
      Map.merge(
        %{
          instrument_type: :equity,
          symbol: "AAPL",
          side: :sell,
          order_type: :trailing_stop,
          time_in_force: :gtc,
          quantity: Decimal.new("1"),
          trailing_stop_step: Decimal.new("1.5")
        },
        overrides
      )
    end

    test "the type is required, never defaulted, in Rest and in the Fake alike" do
      refusal = {:error, {:missing_field, :trailing_type}}

      assert refusal == Rest.validate_order_request(trailing(%{}))

      assert refusal ==
               Rest.place_order(@credentials, trailing(%{}),
                 account_id: @account,
                 plug: answering(200, [])
               )

      assert hits() == 0

      assert refusal == Fake.place_order(@credentials, trailing(%{}), account_id: @account)
    end

    test "only AMOUNT and PERCENTAGE are types" do
      for bad <- [:ratio, "amount", 5, %{}] do
        assert {:error, {:invalid_trailing_type, ^bad}} =
                 Rest.validate_order_request(trailing(%{trailing_type: bad}))
      end
    end

    test "a type on any other order type is refused, not dropped" do
      request =
        %{
          order_type: :limit,
          time_in_force: :day,
          price: Decimal.new("10"),
          trailing_type: :amount
        }
        |> trailing()
        |> Map.delete(:trailing_stop_step)

      assert {:error, {:unexpected_field, :trailing_type}} =
               Rest.validate_order_request(request)
    end

    test "a percentage step above 1 is refused and 1 is not" do
      percentage = %{trailing_type: :percentage}

      assert {:error, {:invalid_trailing_stop_step, over}} =
               Rest.validate_order_request(
                 trailing(Map.put(percentage, :trailing_stop_step, Decimal.new("1.01")))
               )

      assert Decimal.equal?(over, Decimal.new("1.01"))

      assert :ok =
               Rest.validate_order_request(
                 trailing(Map.put(percentage, :trailing_stop_step, Decimal.new("1")))
               )

      assert :ok =
               Rest.validate_order_request(
                 trailing(%{trailing_type: :amount, trailing_stop_step: Decimal.new("25")})
               )
    end

    test "the type and the step both reach the wire" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:body, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"client_order_id" => "t-1"}]))
      end

      assert {:ok, %{id: "t-1"}} =
               Rest.place_order(
                 @credentials,
                 trailing(%{
                   client_order_id: "t-1",
                   trailing_type: "PERCENTAGE",
                   trailing_stop_step: Decimal.new("0.5")
                 }),
                 account_id: @account,
                 plug: plug
               )

      assert_received {:body, body}
      [leaf] = body["new_orders"]
      assert leaf["trailing_type"] == "PERCENTAGE"
      assert leaf["trailing_stop_step"] == "0.5"
    end
  end

  describe "a read reads a 4xx as a refusal too" do
    test "417, 409, 422 and 400 are refusals, never retried" do
      for status <- [400, 409, 417, 422] do
        assert {:refused, {:venue_error, ^status, "no"}} =
                 Rest.get_accounts(@credentials,
                   plug: answering(status, %{"message" => "no"}),
                   retry_attempts: 3,
                   retry_delay: 1
                 ),
               "#{status} was not a refusal"

        assert hits() == 1
      end
    end

    test "a POST read answers the same way, once" do
      assert {:refused, {:venue_error, 417, "NO: bad"}} =
               Rest.check_token("t", @credentials,
                 plug: answering(417, %{"error_code" => "NO", "message" => "bad"}),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert hits() == 1
    end

    test "408 stays an error and a 404 is :not_found" do
      assert {:error, {:exchange_error, :webull, "HTTP 408" <> _rest}} =
               Rest.get_accounts(@credentials, plug: answering(408, %{}), retry_attempts: 1)

      assert {:refused, :not_found} =
               Rest.get_accounts(@credentials, plug: answering(404, %{}), retry_attempts: 1)
    end
  end

  describe "a futures order changes type one way only" do
    defp futures_replace(module, from, to) do
      module.replace_order(@credentials, "abc", %{order_type: to},
        account_id: @account,
        instrument_type: :futures,
        order_type: from,
        plug: answering(200, [])
      )
    end

    test "limit and stop may become market, stop_limit may become limit" do
      assert {:error, {:unsupported_order_type_change, :limit, :stop}} =
               futures_replace(Rest, :limit, :stop)

      assert {:error, {:unsupported_order_type_change, :stop, :limit}} =
               futures_replace(Rest, :stop, :limit)

      assert {:error, {:unsupported_order_type_change, :stop_limit, :market}} =
               futures_replace(Rest, :stop_limit, :market)

      assert hits() == 0
    end

    test "the Fake refuses exactly as Rest does" do
      for {from, to} <- [limit: :stop, stop: :limit, stop_limit: :market] do
        assert futures_replace(Rest, from, to) == futures_replace(Fake, from, to)
      end
    end

    test "the allowed directions are not refused locally" do
      for {from, to} <- [limit: :market, stop: :market, stop_limit: :limit] do
        result = futures_replace(Rest, from, to)
        refute match?({:error, {:unsupported_order_type_change, _from, _to}}, result)
      end
    end

    test "an equity order has no such rule" do
      result =
        Rest.replace_order(@credentials, "abc", %{order_type: :market},
          account_id: @account,
          instrument_type: :equity,
          order_type: :limit,
          plug: answering(200, [])
        )

      refute match?({:error, {:unsupported_order_type_change, _from, _to}}, result)
    end
  end

  describe "the watchlist instrument category is the documented enum" do
    test "only US_STOCK, in Rest and in the Fake, before anything is sent" do
      opts = [category: "US_ETF", plug: answering(200, [%{"success" => true}])]

      assert {:error, {:invalid_category, "US_ETF"}} =
               Rest.add_watchlist_instruments("wl-1", ["AAPL"], @credentials, opts)

      assert {:error, {:invalid_category, "US_ETF"}} =
               Rest.remove_watchlist_instruments("wl-1", ["AAPL"], @credentials, opts)

      sorted = [sorts: %{"AAPL" => 1}] ++ opts

      assert {:error, {:invalid_category, "US_ETF"}} =
               Rest.sort_watchlist_instruments("wl-1", @credentials, sorted)

      assert {:error, {:invalid_category, "US_ETF"}} =
               Rest.create_watchlist("n", ["AAPL"], @credentials, opts)

      assert hits() == 0

      fake = [category: "US_ETF", credentials: @credentials]

      assert {:error, {:invalid_category, "US_ETF"}} =
               Fake.add_watchlist_instruments("wl-1", ["AAPL"], fake)

      assert {:error, {:invalid_category, "US_ETF"}} = Fake.create_watchlist("n", ["AAPL"], fake)

      assert {:error, {:invalid_category, "US_ETF"}} =
               Fake.sort_watchlist_instruments("wl-1", [sorts: %{"AAPL" => 1}] ++ fake)
    end

    test "US_STOCK and an absent category are sent" do
      assert {:ok, %{"success" => true}} =
               Rest.add_watchlist_instruments("wl-1", ["AAPL"], @credentials,
                 category: "US_STOCK",
                 plug: answering(200, [%{"success" => true}])
               )

      assert hits() == 1
    end
  end

  describe "a refusal body" do
    test "an error_code alone is the reason, and a message beside it is kept after the code" do
      assert {:refused, {:venue_error, 401, "UNAUTHORIZED"}} =
               Rest.get_accounts(@credentials,
                 plug: answering(401, %{"error_code" => "UNAUTHORIZED"})
               )

      assert {:refused, {:venue_error, 401, "UNAUTHORIZED: Insufficient permission"}} =
               Rest.get_accounts(@credentials,
                 plug:
                   answering(401, %{
                     "error_code" => "UNAUTHORIZED",
                     "message" => "Insufficient permission"
                   })
               )
    end
  end
end
