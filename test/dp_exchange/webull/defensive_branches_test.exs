defmodule DpExchange.Webull.DefensiveBranchesTest do
  @moduledoc """
  The clauses that exist so something cannot happen.

  Each targets a branch no ordinary call reaches: a shape the venue sends once and never
  again, a status between success and refusal, a number arriving as a different JSON type.
  Every one of them encodes the same decision — refuse, or carry the absence forward, never
  substitute something plausible — and a branch nobody has exercised is a decision nobody
  has checked.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter}
  alias DpExchange.Webull.{Fake, Feed, Rest, Subscription}

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

    limiter = :"lim_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  @credentials %{app_key: "k", app_secret: "s"}

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp raw(body, status \\ 200) do
    fn conn -> Plug.Conn.resp(conn, status, body) end
  end

  describe "response shapes the venue sends rarely" do
    test "a body wrapped in a data key is unwrapped" do
      body = %{"data" => [%{"price" => "1", "time" => 1_787_936_147_000}]}

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("1"))
    end

    test "a bare object is treated as a single row" do
      body = %{"price" => "1", "time" => 1_787_936_147_000}

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a body that is neither list nor map is an unreadable response" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: raw("\"just a string\""),
                 retry_attempts: 0
               )
    end

    test "an empty list is an unreadable snapshot, not a nil-priced quote" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials, plug: responding([]), retry_attempts: 0)
    end

    test "an EMPTY-STRING field counts as absent, not as a value" do
      # Passing "" on as a price turns a missing field into an unparseable number a layer
      # down, which is a worse place to discover it.
      body = [%{"price" => "", "lastPrice" => "2", "time" => 1_787_936_147_000}]

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("2"))
    end

    test "a non-JSON body decodes to nothing rather than crashing" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: raw("<html>maintenance</html>"),
                 retry_attempts: 0
               )
    end

    test "numbers arriving as JSON numbers still become Decimals" do
      # JSON has one number type, so a venue emitting 1 and one emitting "1.00" mean the
      # same thing and both must reach Decimal.
      body = [%{"price" => 1, "bidPrice" => 0.5, "time" => 1_787_936_147_000}]

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new(1))
      assert Decimal.equal?(quote_struct.bid, Decimal.from_float(0.5))
    end
  end

  describe "statuses between success and refusal" do
    test "a 404 is an error naming the status, not a refusal" do
      # This venue states refusals in a 400/401/403 body. A 404 is the shape of a wrong
      # URL, which is our bug rather than the venue's answer.
      assert {:error, {:exchange_error, :webull, message}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(%{}, 404),
                 retry_attempts: 0
               )

      assert message =~ "404"
    end

    test "a refusal with only a code still carries it" do
      body = %{"code" => "AUTH_FAILED"}

      assert {:refused, {:venue_error, "AUTH_FAILED"}} =
               Rest.get_price("BTC-USD", @credentials,
                 plug: responding(body, 403),
                 retry_attempts: 0
               )
    end

    test "a refusal with neither code nor message is still a refusal" do
      assert {:refused, :refused} =
               Rest.get_price("BTC-USD", @credentials, plug: raw("nope", 401), retry_attempts: 0)
    end
  end

  describe "timestamps" do
    test "a seconds epoch as a STRING is read" do
      body = [%{"price" => "1", "time" => "1787936147"}]

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)

      assert quote_struct.timestamp.year == 2026
    end

    test "a timestamp of an unexpected TYPE is an error, not a guess" do
      body = [%{"price" => "1", "time" => %{"nested" => true}}]

      assert {:error, {:unparseable_venue_timestamp, _value}} =
               Rest.get_price("BTC-USD", @credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "candle range bounds" do
    @bars [
      %{
        "result" => [
          %{
            "open" => "1",
            "high" => "1",
            "low" => "1",
            "close" => "1",
            "time" => 1_787_935_740_000
          },
          %{
            "open" => "2",
            "high" => "2",
            "low" => "2",
            "close" => "2",
            "time" => 1_787_935_680_000
          }
        ]
      }
    ]

    test "an :end bound filters from the top" do
      finish = DateTime.from_unix!(1_787_935_700_000, :millisecond)

      assert {:ok, [bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [end: finish], @credentials,
                 plug: responding(@bars),
                 retry_attempts: 0
               )

      assert bar.timestamp == DateTime.from_unix!(1_787_935_680_000, :millisecond)
    end

    test "a limit is passed to the venue rather than applied here" do
      plug = fn conn ->
        assert conn.query_string =~ "count=5"
        Req.Test.json(conn, @bars)
      end

      assert {:ok, _bars} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: plug,
                 limit: 5,
                 retry_attempts: 0
               )
    end

    test "a group carrying neither rows nor bar fields contributes nothing" do
      assert {:ok, []} =
               Rest.get_historical_prices("BTC-USD", "1m", [], @credentials,
                 plug: responding(["not a map"]),
                 retry_attempts: 0
               )
    end
  end

  describe "the HTTP half of subscribing" do
    test "a refusal is reported with its status", %{limiter: limiter} do
      assert {:error, {:refused, 401, _body}} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 credentials: @credentials,
                 limiter: limiter,
                 plug: responding(%{"msg" => "bad key"}, 401),
                 retry_attempts: 0
               )
    end

    test "an unexpected status is an error naming it", %{limiter: limiter} do
      assert {:error, {:exchange_error, :webull, message}} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 credentials: @credentials,
                 limiter: limiter,
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )

      assert message =~ "500"
    end

    test "missing credentials refuse before any request", %{limiter: limiter} do
      assert {:error, {:missing_credentials, :webull}} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 limiter: limiter,
                 retry_attempts: 0
               )
    end

    test "the venue's own topic names are sent", %{limiter: limiter} do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end

      :ok =
        Subscription.subscribe("s", ["BTC-USD"],
          credentials: @credentials,
          limiter: limiter,
          plug: plug,
          retry_attempts: 0
        )

      assert_receive {:body, body}
      assert body["sub_types"] == ["snapshot", "quote"]
      assert body["category"] == "US_CRYPTO"
    end
  end

  describe "the facade's streaming callbacks reach the feed" do
    test "subscribe, unsubscribe, update and notices all route", %{limiter: limiter} do
      unique = System.unique_integer([:positive])
      name = :"route_feed_#{unique}"
      {:ok, _feed} = Feed.start_link(name: name, socket: self())

      opts = [
        feed: name,
        credentials: @credentials,
        limiter: limiter,
        plug: fn conn -> Req.Test.json(conn, %{}) end,
        retry_attempts: 0,
        to: self()
      ]

      assert :ok = DpExchange.Webull.subscribe(["BTC-USD"], opts)
      assert :ok = DpExchange.Webull.update_symbols(["BTC-USD"], opts)
      assert :ok = DpExchange.Webull.unsubscribe(["BTC-USD"], opts)
      assert :ok = DpExchange.Webull.subscribe_notices(opts)
    end
  end

  describe "the fake's short arities" do
    test "subscribe and subscribe_notices work without options" do
      assert :ok = Fake.subscribe(["BTC-USD"])
      assert :ok = Fake.subscribe_notices()
    end
  end
end
