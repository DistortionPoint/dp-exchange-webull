defmodule DpExchange.Webull.FailClosedEdgesTest do
  @moduledoc """
  Requests this package used to send, or answers it used to give, that a caller could not
  tell from the right ones. Found reviewing the REST and socket paths on 2026-10-10.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.{Fake, Rest, Socket}

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

  @credentials %{app_key: "test-key", app_secret: "test-secret"}

  defp counting(counter, status, body) do
    fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.json(%{conn | status: status}, body)
    end
  end

  describe "bar ranges a venue endpoint cannot honour are refused" do
    test "futures and event bars refuse a range instead of answering with the latest bars" do
      range = [start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z]]

      for {category, kind} <- [{"US_FUTURES", :future}, {"US_EVENT", :event}] do
        assert {:error, {:unsupported_bar_range, ^kind}} =
                 Rest.get_historical_prices("SYM", "1h", range, @credentials,
                   category: category,
                   retry_attempts: 0
                 )
      end
    end

    test "a crypto range older than the page reaches is refused, not answered short" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..200 do
          at = now |> DateTime.add(-n * 60) |> DateTime.to_unix(:millisecond)

          %{
            "time" => at,
            "open" => "1",
            "high" => "1",
            "low" => "1",
            "close" => "1",
            "volume" => "1"
          }
        end

      body = [%{"symbol" => "BTCUSD", "result" => rows}]
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:error, {:range_exceeds_count, 200}} =
               Rest.get_historical_prices(
                 "BTC-USD",
                 "1m",
                 [start: DateTime.add(now, -86_400)],
                 @credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a crypto count past the venue's 1200 is refused" do
      assert {:error, {:limit_out_of_range, 5_000, max: 1_200}} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 limit: 5_000,
                 retry_attempts: 0
               )
    end
  end

  describe "order writes" do
    test "a limit with no price, or a stop with no trigger, is refused before it is sent" do
      base = %{
        symbol: "AAPL",
        side: :buy,
        quantity: Decimal.new(1),
        time_in_force: :day,
        instrument_type: :equity
      }

      assert {:error, {:missing_required_field, :price}} =
               Rest.validate_order_request(Map.put(base, :order_type, :limit))

      assert {:error, {:missing_required_field, :stop_price}} =
               Rest.validate_order_request(Map.put(base, :order_type, :stop))
    end

    test "a missing side is a named refusal, not a KeyError" do
      request = %{
        symbol: "AAPL",
        order_type: :market,
        time_in_force: :day,
        quantity: Decimal.new(1),
        instrument_type: :equity
      }

      assert {:error, {:missing_required_field, :side}} = Rest.validate_order_request(request)
    end

    test "a failed place returns the client_order_id, so the caller can look the order up" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end

      request = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :market,
        time_in_force: :day,
        quantity: Decimal.new(1),
        client_order_id: "mine-1",
        instrument_type: :equity
      }

      assert {:error, {:order_unconfirmed, "mine-1", _reason}} =
               Rest.place_order(@credentials, request, account_id: "acct-1", plug: plug)
    end

    test "the OAuth token exchange is sent once, never retried" do
      counter = :counters.new(1, [])

      assert {:error, _reason} =
               Rest.oauth_token("CLIENT", "secret",
                 code: "single-use",
                 plug: counting(counter, 503, %{}),
                 retry_delay: 1
               )

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "the fake answers as the real path does" do
    test "it echoes the caller's client_order_id and refuses an unsized order" do
      request = %{
        symbol: "AAPL",
        side: :buy,
        order_type: :market,
        time_in_force: :day,
        quantity: Decimal.new(1),
        client_order_id: "mine-2",
        instrument_type: :equity
      }

      assert {:ok, %{id: "mine-2"}} = Fake.place_order(@credentials, request, account_id: "a")

      assert {:error, :missing_order_size} =
               Fake.place_order(@credentials, Map.delete(request, :quantity), account_id: "a")
    end

    test "its replace refuses a stop price on a limit order, as the real table does" do
      assert {:error, {:unsupported_order_edit, :limit, [:stop_price]}} =
               Fake.replace_order(@credentials, "id-1", %{stop_price: Decimal.new(1)},
                 account_id: "a",
                 order_type: :limit
               )
    end
  end

  describe "a broker that refuses the session backs the reconnect off" do
    test "a session that never reached CONNACK 0 counts toward the delay" do
      state = %{
        connected?: false,
        unconnected_sessions: 1,
        buffer: <<>>,
        ping: nil,
        subscriber: self(),
        session_id: "s1"
      }

      {elapsed_us, {:reconnect, after_drop}} =
        :timer.tc(fn -> Socket.handle_disconnect(%{reason: :closed}, state) end)

      assert after_drop.unconnected_sessions == 2
      assert elapsed_us >= Socket.reconnect_delay_ms(3) * 1_000
    end
  end
end
