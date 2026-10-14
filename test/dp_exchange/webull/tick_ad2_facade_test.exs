defmodule DpExchange.Webull.TickAD2FacadeTest do
  @moduledoc """
  Facade consistency (design 2026-10-14): D1 not-listed, D4 notice reasons, D7 malformed
  credentials, D8 plaintext URL, D10 `wanted/1`. Real path and Fake each.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull
  alias DpExchange.Webull.{Auth, Fake, Feed, Rest, Socket}

  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}

  defp responding(body, status) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp request_opts(plug), do: [plug: plug, retry_attempts: 0]

  defp bars(category, opts),
    do: Rest.get_historical_prices("NOPE", "1m", [], @credentials, [category: category] ++ opts)

  describe "D1: a symbol the venue does not list is {:refused, :not_listed}" do
    test "a 417 INVALID_SYMBOL on a single-symbol read is a refusal, not a retryable error" do
      plug = responding(%{"error_code" => "INVALID_SYMBOL", "message" => "no such"}, 417)

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", @credentials, request_opts(plug))

      assert {:refused, :not_listed} =
               Rest.get_top_of_book("NOPE-USD", @credentials, request_opts(plug))

      assert {:refused, :not_listed} =
               Rest.get_order_book("NOPE", @credentials, request_opts(plug))

      assert {:refused, :not_listed} = Rest.get_trades("NOPE", @credentials, request_opts(plug))

      assert {:refused, :not_listed} =
               Rest.quantization("NOPE-USD", @credentials, request_opts(plug))

      assert {:refused, :not_listed} =
               Rest.get_historical_prices("NOPE-USD", "1m", [], @credentials, request_opts(plug))
    end

    test "a 400 INVALID_SYMBOL is the same refusal, with no venue text in the reason" do
      plug = responding(%{"msg" => "INVALID_SYMBOL: NOPE"}, 400)

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", @credentials, request_opts(plug))
    end

    test "a 404 on a single-symbol read is :not_listed" do
      assert {:refused, :not_listed} =
               Rest.get_top_of_book("NOPE-USD", @credentials, request_opts(responding(%{}, 404)))
    end

    test "a 4xx that does not name the symbol stays the generic error, and 401 stays a refusal" do
      assert {:error, {:exchange_error, :webull, "HTTP 417" <> _rest}} =
               Rest.get_price(
                 "BTC-USD",
                 @credentials,
                 request_opts(responding(%{"error_code" => "OTHER"}, 417))
               )

      assert {:refused, {:venue_error, 401, _detail}} =
               Rest.get_price(
                 "BTC-USD",
                 @credentials,
                 request_opts(responding(%{"msg" => "no"}, 401))
               )
    end

    test "every other single-symbol read answers :not_listed on a 404 and on INVALID_SYMBOL" do
      plugs = [
        responding(%{}, 404),
        responding(%{"error_code" => "INVALID_SYMBOL"}, 417),
        responding(%{"msg" => "INVALID_SYMBOL"}, 400)
      ]

      reads = [
        {"futures bars", &bars("US_FUTURES", &1)},
        {"option bars", &bars("US_OPTION", &1)},
        {"event bars", &bars("US_EVENT", &1)},
        {"stock bars", &bars("US_STOCK", &1)},
        {"volume profile", &Rest.get_volume_profile("NOPE", "5m", @credentials, &1)},
        {"auction imbalance",
         &Rest.get_auction_imbalance("NOPE", @credentials, [auction: :opening] ++ &1)},
        {"financials", &Rest.get_financials("NOPE", :balance_sheet, @credentials, &1)},
        {"dividends", &Rest.get_fundamental(:fund_dividends, "NOPE", @credentials, &1)},
        {"filings", &Rest.get_filings("NOPE", @credentials, &1)},
        {"event trades", &Rest.get_event_trades("NOPE", @credentials, &1)},
        {"event order book", &Rest.get_event_order_book("NOPE", @credentials, &1)}
      ]

      for {name, read} <- reads, plug <- plugs do
        assert {name, {:refused, :not_listed}} == {name, read.(request_opts(plug))}
      end
    end

    test "the Fake answers :not_listed for a crypto-shaped pair on the equity-only reads" do
      opts = [credentials: @credentials]

      assert {:refused, :not_listed} = Fake.get_volume_profile("NOPE-USD", "5m", opts)

      assert {:refused, :not_listed} =
               Fake.get_auction_imbalance("NOPE-USD", [auction: :opening] ++ opts)

      assert {:refused, :not_listed} = Fake.get_financials("NOPE-USD", :balance_sheet, opts)
      assert {:refused, :not_listed} = Fake.get_filings("NOPE-USD", opts)
    end

    test "a 404 on something that is not a symbol read is still :not_found" do
      assert {:refused, :not_found} =
               Rest.get_order(@credentials, "5f1e9c0a7b2d4e68a3c4d5e6f7081920",
                 account_id: "acct",
                 plug: responding(%{}, 404),
                 retry_attempts: 0
               )
    end

    test "the Fake answers the same word" do
      assert {:refused, :not_listed} = Fake.get_price("NOPE-USD", credentials: @credentials)
      assert {:refused, :not_listed} = Fake.get_top_of_book("NOPE-USD", credentials: @credentials)
    end
  end

  describe "D4: an unparsed venue notice" do
    test "is :data_quality with an atom reason and the text in details.message" do
      body = <<byte_size("notice")::16>> <> "notice" <> "Permission grabbed by other session"
      frame = <<3::4, 0::4, byte_size(body)>> <> body

      state = %{
        subscriber: self(),
        session_id: "s-1",
        app_key: "k",
        buffer: <<>>,
        qos2_pending: MapSet.new(),
        connected?: false,
        ping: nil,
        last_heard_at: nil
      }

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state)

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}, 5_000
      assert notice.details.reason == :unparsed_venue_notice
      assert notice.details.message == "Permission grabbed by other session"
      assert is_atom(notice.details.reason)
    end
  end

  describe "D7: malformed credentials" do
    test "surrounding whitespace or a control character is refused before signing" do
      request = %{
        path: "/x",
        query_params: %{},
        body: "",
        host: "h.example",
        timestamp: "t",
        nonce: "n"
      }

      for bad <- ["key\n", " key", "key ", "ke\ty", "k\0ey", "key\r"] do
        assert {:error, {:invalid_credentials, :webull}} =
                 Auth.headers(request, %{app_key: bad, app_secret: "good-secret"})

        assert {:error, {:invalid_credentials, :webull}} =
                 Auth.headers(request, %{app_key: "good-key", app_secret: bad})

        assert {:error, {:invalid_credentials, :webull}} =
                 Auth.headers(request, %{
                   app_key: "good-key",
                   app_secret: "good-secret",
                   access_token: bad
                 })
      end

      assert {:ok, _headers} =
               Auth.headers(request, %{app_key: "good-key", app_secret: "good-secret"})
    end

    test "a blank value is still missing, not invalid" do
      assert {:error, {:missing_credentials, :webull}} =
               Auth.present?(%{app_key: " ", app_secret: "s"})
    end

    test "the real path refuses without sending, and never echoes the value" do
      plug = fn _conn -> flunk("nothing may be sent with a malformed credential") end
      secret = "leaky-secret-value\n"

      assert {:error, {:invalid_credentials, :webull} = reason} =
               Rest.get_price("BTC-USD", %{app_key: "k", app_secret: secret}, request_opts(plug))

      refute inspect(reason) =~ "leaky"
      assert Rest.unsent?(reason)
    end

    test "the Fake refuses the same way" do
      creds = %{app_key: "key\n", app_secret: "secret"}

      assert {:error, {:invalid_credentials, :webull}} =
               Fake.get_price("BTC-USD", credentials: creds)

      assert {:error, {:invalid_credentials, :webull}} = Fake.get_accounts(creds, [])
    end
  end

  describe "D8: plaintext URL refusal" do
    test "the stream and the OAuth endpoint both answer {:insecure_url, :webull}" do
      assert {:error, {:insecure_url, :webull}} =
               Socket.start_link(
                 url: "ws://data.example.test/mqtt",
                 subscriber: self(),
                 session_id: "s",
                 app_key: "test-key-not-real"
               )

      assert {:error, {:insecure_url, :webull}} =
               Rest.oauth_token("CLIENT", "test-secret-not-real",
                 code: "c",
                 oauth_url: "http://oauth.example.test",
                 retry_attempts: 0
               )
    end
  end

  describe "D10: wanted/1" do
    test "the real feed answers the sorted symbols it was asked to stream" do
      feed = start_feed(shards: %{})
      assert Feed.wanted(feed) == []

      :sys.replace_state(feed, fn state ->
        %{state | wanted: MapSet.new(["ZZZ-USD", "AAA-USD"])}
      end)

      assert Feed.wanted(feed) == ["AAA-USD", "ZZZ-USD"]
      assert Webull.wanted(feed: feed) == ["AAA-USD", "ZZZ-USD"]
      # Wanted is not covered: nothing has arrived.
      assert Webull.coverage(feed: feed) == %{}
    end

    test "with no feed running the facade answers []" do
      assert Webull.wanted(feed: :"no_such_feed_#{System.unique_integer([:positive])}") == []
    end

    test "the Fake reports what it was asked to stream, sorted" do
      assert Fake.wanted() == []
      assert :ok = Fake.subscribe(["ETH-USD", "BTC-USD"], credentials: @credentials)
      assert Fake.wanted() == ["BTC-USD", "ETH-USD"]
      assert :ok = Fake.update_symbols(["BTC-USD"], credentials: @credentials)
      assert Fake.wanted() == ["BTC-USD"]
    end
  end
end
