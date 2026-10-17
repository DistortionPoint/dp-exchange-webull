defmodule DpExchange.Webull.TickAJTest do
  @moduledoc """
  Tick AJ: an option or a window this venue cannot honour is refused rather than ignored, an
  inverted range is refused rather than answered empty, and an ISO "unknown" time is no more a
  real time than an epoch of 0. Every test names the input and what the old code did with it.
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
  @fake_opts [credentials: @credentials]

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp answer(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    [plug: plug, retry_attempts: 0]
  end

  describe "get_order_book/3: limit is not a depth option" do
    test "limit: is refused by name on the real path, before anything is sent" do
      # Old: `limit: 5` was dropped and the venue's default ten levels came back, a different
      # amount of data than was asked for with every value in it correct.
      assert {:error, {:unsupported_option, :limit}} =
               Rest.get_order_book("AAPL", @credentials, plug: exploding(), limit: 5)
    end

    test "limit: is refused by the Fake the same way, and a nil limit is absent" do
      assert {:error, {:unsupported_option, :limit}} =
               Fake.get_order_book("AAPL", [limit: 5] ++ @fake_opts)

      assert {:ok, %{bids: [_bid | _more_bids]}} =
               Fake.get_order_book("AAPL", [limit: nil] ++ @fake_opts)
    end

    test "depth: still bounds the levels" do
      assert {:ok, %{bids: [_one], asks: [_other]}} =
               Fake.get_order_book("AAPL", [depth: 1] ++ @fake_opts)
    end
  end

  describe "get_trades/3: the tick endpoints take a count and no start time" do
    test "since: is refused by name on the real path for every tape category" do
      for category <- ["US_STOCK", "US_ETF", "US_OPTION", "US_FUTURES"] do
        assert {:error, {:unsupported_option, :since}} =
                 Rest.get_trades("AAPL", @credentials,
                   category: category,
                   since: ~U[2026-01-01 00:00:00Z],
                   plug: exploding()
                 )
      end
    end

    test "since: is refused by the Fake the same way" do
      assert {:error, {:unsupported_option, :since}} =
               Fake.get_trades("AAPL", [since: ~U[2026-01-01 00:00:00Z]] ++ @fake_opts)

      assert {:ok, [_trade | _more_trades]} = Fake.get_trades("AAPL", [since: nil] ++ @fake_opts)
    end
  end

  describe "an inverted range" do
    test "start after end is refused on every bars path, not answered with no bars" do
      # Old: every bar was filtered out and `{:ok, []}` read as "no trading in that period".
      range = [start: ~U[2026-03-01 00:00:00Z], end: ~U[2026-02-01 00:00:00Z]]

      for category <- ["US_CRYPTO", "US_STOCK", "US_OPTION", "US_FUTURES"] do
        assert {:error, {:invalid_range, ^range}} =
                 Rest.get_historical_prices(
                   "BTC-USD",
                   "1d",
                   range,
                   @credentials,
                   category: category,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end

      assert {:error, {:invalid_range, ^range}} =
               Fake.get_historical_prices("BTC-USD", "1d", range, @fake_opts)
    end

    test "start equal to end is a genuinely empty window and stays valid" do
      at = ~U[2026-02-01 00:00:00Z]

      assert :ok = Rest.validate_range(start: at, end: at)
      assert :ok = Rest.validate_range(start: at)
      assert :ok = Rest.validate_range(end: at)
      assert :ok = Rest.validate_range([])
    end
  end

  describe "an ISO venue time is held to the epoch rule" do
    defp tape(time) do
      [
        %{
          "symbol" => "AAPL",
          "result" => [%{"time" => time, "price" => "10", "volume" => "1"}]
        }
      ]
    end

    test "the 1970 and year-1 sentinels are refused, as an epoch of 0 is" do
      # Old: both parsed as real instants and went out as a trade's timestamp.
      for sentinel <- ["1970-01-01T00:00:00Z", "0001-01-01T00:00:00Z"] do
        assert {:error, :invalid_unix_time} =
                 Rest.get_trades("AAPL", @credentials, answer(tape(sentinel)))
      end
    end

    test "a real ISO time is delivered as the instant it states" do
      assert {:ok, [trade]} =
               Rest.get_trades("AAPL", @credentials, answer(tape("2026-08-01T10:00:00Z")))

      assert trade.timestamp == ~U[2026-08-01 10:00:00Z]
    end
  end

  describe "oauth grants: a blank grant is no grant" do
    test "a blank code is refused by name before anything is sent" do
      # Old: `code: ""` was sent as an authorization_code grant for the venue to refuse.
      for blank <- ["", "   "] do
        assert {:error, :code_or_refresh_token_required} =
                 Rest.oauth_token("id", "secret", code: blank, plug: exploding())

        assert {:error, :code_or_refresh_token_required} =
                 Rest.validate_oauth_request("id", "secret", code: blank)
      end
    end

    test "a blank refresh token beside a real code is the code grant, not an exclusive clash" do
      assert :ok = Rest.validate_oauth_request("id", "secret", code: "abc", refresh_token: "")
    end
  end

  describe "order windows" do
    @account "93IUJ28O9VO2KBGHDHR4H9"

    test "since/until on the open listing are refused, on the real path and the Fake" do
      for key <- [:since, :until] do
        opts = [{key, ~U[2026-01-01 00:00:00.000Z]}, account_id: @account]

        assert {:error, {:unsupported_option, ^key}} =
                 Rest.get_orders(@credentials, [plug: exploding(), retry_attempts: 0] ++ opts)

        assert {:error, {:unsupported_option, ^key}} = Fake.get_orders(@credentials, opts)
      end
    end

    test "an unbounded history read is unaffected" do
      assert {:ok, []} =
               Rest.get_orders(
                 @credentials,
                 [history: true, account_id: @account] ++ answer([])
               )
    end
  end
end
