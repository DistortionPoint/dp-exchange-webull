defmodule DpExchange.Webull.ReferenceDataTest do
  @moduledoc """
  Fundamentals, screeners and news — thirty endpoints under three shapes.

  **The parameter table is the assertion.** Every fundamentals endpoint takes `symbol` and
  `category` and differs only in what it adds, and a parameter that belongs to one must not
  leak into another: `type` and `count` are real on a balance sheet and unknown on a dividend
  calendar, and an unknown parameter is at best ignored and at worst a refusal — neither of
  which tells the caller which happened.

  Two mappings are stated rather than guessed. **`fiscal_period` keeps the venue's integer
  code**, because "Q1" would lose the distinction between a fiscal and a calendar quarter.
  And a screener's **rank is the position the venue returned the row in** — this package
  publishes no ranking of its own, because two venues' "top movers" answer different
  questions.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # Server-Sent Events — the real shape `news-summary.md:195` documents for
  # `POST /market-data/news/summaries/get`, and the only endpoint in this file that
  # answers this way rather than with JSON. `events` is a list of maps, each becoming one
  # `event:message\ndata:{...}` frame.
  defp sse_body(events),
    do: Enum.map_join(events, "\n\n", &"event:message\ndata:#{Jason.encode!(&1)}")

  defp sse_responding(events) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, sse_body(events))
    end
  end

  defp sse_capturing(events, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, sse_body(events))
    end
  end

  describe "the fundamentals table" do
    test "every kind names a path, and there are twenty-three of them" do
      kinds = Rest.fundamental_kinds()
      assert length(kinds) == 23
      assert :balance_sheet in kinds
      assert :industry_comparisons in kinds
    end

    test "a kind this venue does not publish is refused before a request is made" do
      # Guessing a path from an atom would produce a 404 that reads like a venue outage.
      assert {:error, {:unknown_fundamental, :cash_burn}} =
               Rest.get_fundamental(:cash_burn, "AAPL", @credentials, [])
    end

    test "symbol and category always go, and category defaults to the only one documented" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:company_profile, "AAPL", @credentials,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/company-profiles/get"
      assert query =~ "symbol=AAPL"
      assert query =~ "category=US_STOCK"
    end

    test "type and count reach the endpoints that document them" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:balance_sheet, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/fundamentals/balance-sheets/get"
      assert query =~ "type=ANNUAL"
      assert query =~ "count=20"
    end

    test "and are dropped on the endpoints that do not" do
      # A parameter an endpoint does not know is at best ignored and at worst a refusal.
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:dividend_calendar, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 20,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      refute query =~ "type="
      refute query =~ "count="
    end

    test "capital flows take count but not type" do
      me = self()

      assert {:ok, []} =
               Rest.get_fundamental(:capital_flows, "AAPL", @credentials,
                 type: "ANNUAL",
                 count: 5,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "count=5"
      refute query =~ "type="
    end

    test "rows come back as the venue sent them" do
      body = [%{"fiscal_year" => 2026, "total_assets" => "379297000000"}]

      assert {:ok, [row]} =
               Rest.get_fundamental(:balance_sheet, "AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["total_assets"] == "379297000000"
    end

    # `fund-files.md`, `fund-holdings.md` and `fund-splits.md` each document only `symbol`
    # and `category` — no `count`, unlike `capital_flows` above.
    for kind <- [:fund_files, :fund_holdings, :fund_splits] do
      test "#{kind} does not send count, which its own page does not define" do
        me = self()

        assert {:ok, []} =
                 Rest.get_fundamental(unquote(kind), "AAPL", @credentials,
                   count: 5,
                   plug: capturing([], me),
                   retry_attempts: 0
                 )

        assert_receive {:request, "GET", _path, query, _raw}
        refute query =~ "count="
      end
    end

    test "fund_dividends follows pagination_key bounded, and sends no count" do
      # `fund-dividends.md:36-73` documents `symbol`, `category` and `pagination_key` — no
      # `count`.
      plug = fn conn ->
        body =
          if String.contains?(conn.query_string || "", "pagination_key=page-2") do
            [%{"ex_date" => "2026-06-01"}]
          else
            %{"data" => [%{"ex_date" => "2026-03-01"}], "pagination_key" => "page-2"}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, [%{"ex_date" => "2026-03-01"}, %{"ex_date" => "2026-06-01"}]} =
               Rest.get_fundamental(:fund_dividends, "AAPL", @credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "get_financials/4" do
    test "a statement carries the venue's line items whole" do
      body = [
        %{
          "fiscal_year" => 2026,
          "fiscal_period" => 0,
          "end_date" => "2025-12-27",
          "currency" => "USD",
          "total_assets" => "379297000000"
        }
      ]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert %Types.FinancialStatement{} = statement
      assert statement.symbol == "AAPL"
      assert statement.kind == :balance_sheet
      assert statement.line_items["total_assets"] == "379297000000"
      assert statement.period_end == ~D[2025-12-27]
      assert statement.currency == "USD"
    end

    test "fiscal_period keeps the venue's integer code" do
      # "Q1" would lose the distinction between a fiscal and a calendar quarter.
      body = [%{"fiscal_period" => 3, "end_date" => "2025-09-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :cash_flow, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == "Q3"
    end

    test "a kind that is real but is not a statement is refused" do
      # :company_profile is a real fundamentals kind and is not a financial statement;
      # answering with it would put a profile in a statement's shape.
      assert {:error, {:unsupported_statement_kind, :company_profile}} =
               Rest.get_financials("AAPL", :company_profile, @credentials, [])
    end

    test "an unparsable end date is nil rather than today" do
      body = [%{"end_date" => "not a date"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :income, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.period_end == nil
    end
  end

  describe "get_corporate_events/2" do
    test "the symbol is required, because these calendars are per issuer" do
      # A market-wide calendar and one issuer's are different questions.
      assert {:error, :symbol_required} = Rest.get_corporate_events(@credentials, [])
    end

    test "without a kind both calendars are read" do
      me = self()

      assert {:ok, _events} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", first, _q1, _r1}
      assert_receive {:request, "GET", second, _q2, _r2}

      assert Enum.sort([first, second]) == [
               "/market-data/fundamentals/dividend-calendars/list",
               "/market-data/fundamentals/earnings-calendars/list"
             ]
    end

    test "a kind narrows it to one request" do
      me = self()

      # `dividend-calendar.md:202,207` names `ex_div_date` and `declare_date` — not
      # `ex_dividend_date`/`announce_date`, which no page defines.
      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :dividend,
                 plug: capturing([%{"ex_div_date" => "2026-08-10", "amount" => "0.25"}], me),
                 retry_attempts: 0
               )

      assert event.kind == :dividend
      assert event.ex_date == ~D[2026-08-10]
      assert Decimal.equal?(event.amount, Decimal.new("0.25"))

      assert_receive {:request, "GET", "/market-data/fundamentals/dividend-calendars/list", _q,
                      _r}

      refute_receive {:request, "GET", _other, _q2, _r2}
    end

    test "an earnings row's date is expected_publish_date, carried under announced_date" do
      # `earnings-calendar.md:185` — `Core.Types.CorporateEvent` has no earnings-specific
      # date field, so the venue's one published date for this calendar goes under
      # `:announced_date`; `ex_date`/`record_date`/`pay_date` stay `nil` because they are
      # dividend vocabulary an earnings row has no business populating.
      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :earnings,
                 plug: responding([%{"expected_publish_date" => "2026-08-01"}]),
                 retry_attempts: 0
               )

      assert event.kind == :earnings
      assert event.announced_date == ~D[2026-08-01]
      assert event.ex_date == nil
      # `true` would claim a date is final when an earnings date routinely is not; the
      # venue publishes no confirmed/estimated flag on either calendar.
      assert event.confirmed == nil
    end

    test "a kind this venue has no calendar for is refused" do
      # Webull publishes fund-splits and nothing for equities, so a :split kind would be
      # answerable for some symbols and silently empty for the rest.
      assert {:error, {:unsupported_event_kind, :split}} =
               Rest.get_corporate_events(@credentials, symbol: "AAPL", kind: :split)
    end
  end

  describe "get_filings/3 and get_news/2" do
    # `filings.md:176` documents `{symbol, category, filings: [{title, url,
    # publish_date}]}` — the list under `filings`, not `data`, which `get_fundamental/4`'s
    # generic `rows/1` cannot see on its own; a bare array of filing rows, which this
    # fixture used to send, is not this endpoint's real shape.
    test "a filing points at a url and nothing follows it" do
      body = %{
        "symbol" => "AAPL",
        "category" => "US_STOCK",
        "filings" => [
          %{
            "id" => "f-1",
            "form_type" => "10-Q",
            "title" => "Quarterly report",
            "url" => "https://example.invalid/f-1"
          }
        ]
      }

      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials, plug: responding(body), retry_attempts: 0)

      assert %Types.Filing{form_type: "10-Q", url: "https://example.invalid/f-1"} = filing
    end

    test "news requires symbols and sends them under the venue's nested shape" do
      me = self()

      assert {:ok, _news} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL", "GOOG"],
                 lang: "en",
                 plug:
                   sse_capturing(
                     [%{"type" => "meta", "args" => %{"convId" => 1}}],
                     me
                   ),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/news/summaries/get"
      body = Jason.decode!(raw)

      assert body["category_symbols"] == [
               %{"category" => "US_STOCK", "symbols" => ["AAPL", "GOOG"]}
             ]

      assert body["lang"] == "en"
    end

    test "news without symbols is refused" do
      assert {:error, :symbols_required} = Rest.get_news(@credentials, [])
    end

    # `news-summary.md:195` documents this endpoint's `200` as a Server-Sent Events
    # stream — `event:message\ndata:{"type":"text","message":...}` chunks concatenated
    # into one generated reply, not a JSON list of independently-published items. The
    # vendor's own description is "invokes LLM to generate news summaries"; naming a
    # publisher would attribute a paraphrase to them.
    test "the source is the venue, because the summary is generated" do
      events = [
        %{"type" => "meta", "args" => %{"convId" => "n-1"}},
        %{"type" => "text", "message" => "y"}
      ]

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )

      assert item.id == "n-1"
      assert item.source == "webull"
      assert item.symbols == ["AAPL"]
      assert item.summary == "y"
    end

    test "text chunks are concatenated in the order the venue sent them" do
      events = [
        %{"type" => "meta", "args" => %{"sessionId" => "s-1"}},
        %{"type" => "text", "message" => "Hi"},
        %{"type" => "text", "message" => ", I'm Wally an"},
        %{"type" => "text", "message" => "d I'll help you with this question"}
      ]

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )

      assert item.id == "s-1"
      assert item.summary == "Hi, I'm Wally and I'll help you with this question"
    end

    test "a stream with no meta event has no conversation id, so it is refused" do
      events = [%{"type" => "text", "message" => "orphaned text"}]

      assert {:error, {:missing_required_field, :id}} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )
    end
  end

  describe "a row that cannot supply its own identity is dropped, never given an empty one" do
    # `|| ""` satisfied the contract's non-nil requirement while saying nothing. It is worse
    # than a `nil`: a `nil` is detectable and an empty string is a value, so a consumer
    # keying coverage by symbol gets a live entry named "". `dp_exchange_robinhood` states
    # the rule this follows — "a row missing `symbol` entirely is dropped rather than
    # published under a fabricated one".

    test "a screener row with no symbol is dropped" do
      rows = [%{"symbol" => "AAPL"}, %{"close" => "1"}, %{"symbol" => "MSFT"}]

      assert {:ok, results} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert Enum.map(results, & &1.symbol) == ["AAPL", "MSFT"]
      refute Enum.any?(results, &(&1.symbol == ""))
    end

    test "dropping a screener row does not re-rank the ones that survive" do
      # `rank` is the venue's own returned order — "inventing one from a metric would
      # re-rank the list", and so would closing the gap left by a dropped row.
      rows = [%{"symbol" => "AAPL"}, %{"close" => "1"}, %{"symbol" => "MSFT"}]

      assert {:ok, [first, second]} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert first.rank == 1
      assert second.rank == 3, "the survivor keeps the position the venue returned it in"
    end

    # This news endpoint answers Server-Sent Events, one generated reply per call
    # (`news-summary.md:195`) rather than a JSON list of independently-published rows each
    # naming their own id — see `get_filings/3 and get_news/2`'s own describe block for
    # the full coverage of that shape. `:id` here is the venue's own conversation id
    # (`convId`, falling back to `sessionId`), never a symbol used as a stand-in: the old
    # fallback on a JSON row was `value(row, ["id", "news_id"]) || value(row, ["symbol"])
    # || ""`, and a ticker as an item id is the worst of the three — it looks like an id
    # and collides for every item about the same symbol.
    test "the news item's id prefers convId over sessionId, never a symbol" do
      events = [
        %{"type" => "meta", "args" => %{"sessionId" => "s-1", "convId" => 42}},
        %{"type" => "text", "message" => "x"}
      ]

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: sse_responding(events),
                 retry_attempts: 0
               )

      assert item.id == "42"
    end

    test "a watchlist row with no id is dropped" do
      rows = [%{"watchlist_id" => "w-1", "name" => "Mine"}, %{"name" => "nameless"}]

      assert {:ok, [list]} =
               Rest.list_watchlists(@credentials, plug: responding(rows), retry_attempts: 0)

      assert list.id == "w-1"
    end
  end

  describe "get_screener/3" do
    test "six screeners are published" do
      assert length(Rest.screeners()) == 6
      assert "gainers_losers" in Rest.screeners()
      assert "week52_high_low" in Rest.screeners()
    end

    test "an unknown screener is refused before a request is made" do
      assert {:error, {:unknown_screener, "moon_shots"}} =
               Rest.get_screener("moon_shots", @credentials, [])
    end

    test "the venue's required defaults are sent explicitly" do
      # An omitted required parameter is a refusal a caller cannot read.
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/gainers-losers/list"
      assert query =~ "rank_type=DAY_1"
      assert query =~ "sort_by=CHANGE_RATIO"
    end

    test "a caller's own ranking window wins over the default" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("gainers_losers", @credentials,
                 rank_type: "WEEK_52",
                 direction: "ASC",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "rank_type=WEEK_52"
      assert query =~ "direction=ASC"
    end

    test "each screener sends only the parameters its own page documents" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("market_sectors", @credentials,
                 agg_type: "VOLUME",
                 period: "MO1",
                 rank_type: "DAY_1",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/market-sectors/list"
      assert query =~ "agg_type=VOLUME"
      assert query =~ "period=MO1"
      # `rank_type` belongs to the movers screeners, not this one.
      refute query =~ "rank_type"
    end

    test "the rank is the venue's returned order, not a metric this package chose" do
      body = [
        %{"symbol" => "AAPL", "change_ratio" => "0.01"},
        %{"symbol" => "TSLA", "change_ratio" => "0.09"}
      ]

      assert {:ok, [first, second]} =
               Rest.get_screener("top_actives", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # TSLA's change ratio is larger and it is still second: re-ranking would answer a
      # different question from the one the venue answered.
      assert first.symbol == "AAPL"
      assert first.rank == 1
      assert second.symbol == "TSLA"
      assert second.rank == 2
      assert second.metrics["change_ratio"] == "0.09"
    end

    test "a sector row is named by its own field rather than by an absent symbol" do
      body = [%{"sector_name" => "Technology", "market_value" => "1"}]

      assert {:ok, [row]} =
               Rest.get_screener("market_sectors", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row.symbol == "Technology"
    end

    # `get-top-active.md:51-57` documents `VOLUME` as this screener's own default —
    # `DAY_1` is `gainers_losers`'s ranking window and was never a member of
    # `top_actives`'s `rank_type` enum at all.
    test "top_actives defaults rank_type to VOLUME, not gainers_losers's DAY_1" do
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("top_actives", @credentials,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      assert query =~ "rank_type=VOLUME"
    end

    # `get-week-52-high-low.md:44` documents four `rank_type` values and no default —
    # unlike `top_actives`, a caller who does not say which rank is refused rather than
    # given a guess at one of the four.
    test "week52_high_low requires rank_type — its page names no default" do
      exploding = fn _conn -> raise "must not guess a rank_type this endpoint never defaulted" end

      assert {:error, :rank_type_required} =
               Rest.get_screener("week52_high_low", @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:ok, _rows} =
               Rest.get_screener("week52_high_low", @credentials,
                 rank_type: "NEW_HIGH",
                 plug: responding([]),
                 retry_attempts: 0
               )
    end

    test "market_sector sends sort_by, not agg_type — that belongs to market_sectors" do
      # `get-market-sectors-detail.md:73-90` documents `sort_by` on this endpoint (the
      # singular, `/get`); `agg_type` is `get-market-sectors.md:47-60`'s own parameter, on
      # the plural `/list` endpoint, and was sent on the wrong one of the two before this.
      me = self()

      assert {:ok, _rows} =
               Rest.get_screener("market_sector", @credentials,
                 sector_id: "6391",
                 sort_by: "VOLUME",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/screeners/market-sectors/get"
      assert query =~ "sort_by=VOLUME"
      refute query =~ "agg_type"
    end

    test "market_sectors and market_sector both follow pagination_key, bounded" do
      for name <- ["market_sectors", "market_sector"] do
        plug = fn conn ->
          body =
            if String.contains?(conn.query_string || "", "pagination_key=page-2") do
              [%{"sector_name" => "Energy"}]
            else
              %{"data" => [%{"sector_name" => "Technology"}], "pagination_key" => "page-2"}
            end

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(body))
        end

        assert {:ok, [%{symbol: "Technology"}, %{symbol: "Energy"}]} =
                 Rest.get_screener(name, @credentials,
                   sector_id: "1",
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "the fake and the facade" do
    test "the fake refuses what the package refuses" do
      assert {:error, :symbol_required} = Fake.get_corporate_events(credentials: @credentials)
      assert {:error, :symbols_required} = Fake.get_news(credentials: @credentials)

      assert {:error, {:unknown_screener, "nope"}} =
               Fake.get_screener("nope", credentials: @credentials)
    end

    # Traced regression: the fake checked credentials before the argument, the opposite
    # of `Rest.get_corporate_events/2` and `Rest.get_news/2`'s own order (both run
    # `required_symbol/1`/`required_symbols/1` before anything reaches `Auth.headers/2`).
    # Calling with NEITHER supplied is the one case that surfaces the mismatch: the fake
    # answered `{:missing_credentials, :webull}` where the real facade answers
    # `:symbol_required`/`:symbols_required`, a real (if narrow) way for this fake to be
    # differently capable than the venue it stands in for.
    test "with neither credentials nor the required argument, the argument refusal wins, " <>
           "matching Rest's own check order" do
      assert Fake.get_corporate_events() == {:error, :symbol_required}
      assert Fake.get_news() == {:error, :symbols_required}
    end

    test "the fake's statement keeps the integer fiscal period" do
      assert {:ok, [statement]} =
               Fake.get_financials("AAPL", :balance_sheet, credentials: @credentials)

      assert statement.fiscal_period == "FY"
    end

    test "the fake's news names the venue as the source" do
      assert {:ok, [item]} = Fake.get_news(credentials: @credentials, symbols: ["AAPL"])
      assert item.source == "webull"
    end

    # Every reference-data endpoint here is signed, so the fake refuses without
    # credentials rather than answering where the real venue returns 401. All are outside
    # `Core.AdapterContract`'s `@credentialed` list, so assertion 17 never asks — each
    # call below supplies its own required argument precisely so the credential check is
    # what's actually being proven, not incidentally shadowed by an argument refusal.
    test "the reference-data callbacks need credentials, as the real venue does" do
      assert Fake.get_corporate_events(symbol: "AAPL") ==
               {:error, {:missing_credentials, :webull}}

      assert Fake.get_news(symbols: ["AAPL"]) == {:error, {:missing_credentials, :webull}}
      assert Fake.get_filings("AAPL") == {:error, {:missing_credentials, :webull}}

      assert Fake.get_financials("AAPL", :balance_sheet) ==
               {:error, {:missing_credentials, :webull}}

      assert Fake.get_screener("nope") == {:error, {:missing_credentials, :webull}}
    end

    test "the facade delegates each of the six" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, [_statement]} =
               DpExchange.Webull.get_financials(
                 "AAPL",
                 :balance_sheet,
                 base ++ [plug: responding([%{"end_date" => "2025-12-27"}])]
               )

      assert {:ok, [_event]} =
               DpExchange.Webull.get_corporate_events(
                 base ++ [symbol: "AAPL", kind: :dividend, plug: responding([%{}])]
               )

      assert {:ok, [_filing]} =
               DpExchange.Webull.get_filings(
                 "AAPL",
                 base ++ [plug: responding(%{"filings" => [%{"id" => "f-1"}]})]
               )

      assert {:ok, [_item]} =
               DpExchange.Webull.get_news(
                 base ++
                   [
                     symbols: ["AAPL"],
                     plug: sse_responding([%{"type" => "meta", "args" => %{"convId" => "n-1"}}])
                   ]
               )

      assert {:ok, [_row]} =
               DpExchange.Webull.get_screener(
                 "top_actives",
                 base ++ [plug: responding([%{"symbol" => "AAPL"}])]
               )

      assert {:ok, [_row]} =
               DpExchange.Webull.get_fundamental(
                 :company_profile,
                 "AAPL",
                 base ++ [plug: responding([%{}])]
               )

      assert DpExchange.Webull.fundamental_kinds() == Rest.fundamental_kinds()
      assert DpExchange.Webull.screeners() == Rest.screeners()
    end
  end

  describe "the readers that have to cope with a venue saying something else" do
    test "a fiscal period the venue already worded is passed through" do
      # The legend covers 0–4. A venue that starts sending "FY2026" is sending a label, and
      # a label is what this field wants.
      body = [%{"fiscal_period" => "FY2026", "end_date" => "2025-12-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :indicators, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == "FY2026"
    end

    test "a fiscal period outside the legend is nil, and the integer is still readable" do
      body = [%{"fiscal_period" => 9, "end_date" => "2025-12-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :indicators, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == nil
      assert statement.line_items["fiscal_period"] == 9
    end

    test "an end date that is not a string leaves the period nil" do
      body = [%{"end_date" => 20_251_227}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :cash_flow, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.period_end == nil
    end

    test "a filing with no timestamp the reader knows leaves filed_at nil" do
      body = %{"symbol" => "AAPL", "filings" => [%{"id" => "f-1"}]}

      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials, plug: responding(body), retry_attempts: 0)

      assert filing.filed_at == nil
    end

    # `filings.md:192` documents `publish_date` as a bare `YYYY-MM-DD`, not a
    # `time`/timestamp field — `filed_at` is a `DateTime`, so midnight UTC on the venue's
    # own date satisfies the type (see `filing_time/1`'s own comment).
    test "a filing that carries a publish_date is read, at midnight UTC on that date" do
      body = %{
        "symbol" => "AAPL",
        "filings" => [%{"id" => "f-1", "publish_date" => "2026-08-31"}]
      }

      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials, plug: responding(body), retry_attempts: 0)

      assert filing.filed_at == ~U[2026-08-31 00:00:00Z]
    end

    test "a single symbol reaches get_news/2 as a one-element list" do
      me = self()

      assert {:ok, [_item]} =
               Rest.get_news(@credentials,
                 symbols: "AAPL",
                 plug:
                   sse_capturing(
                     [%{"type" => "meta", "args" => %{"convId" => 1}}],
                     me
                   ),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}

      assert Jason.decode!(raw)["category_symbols"] == [
               %{"category" => "US_STOCK", "symbols" => ["AAPL"]}
             ]
    end

    test "a corporate-event calendar that errors halts rather than returning half" do
      # Concatenating one calendar's rows with the other's failure would report a partial
      # answer as a whole one.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "nope"}))
      end

      assert {:error, _reason} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a paged listing that answers with a bare list still comes back paged" do
      assert {:ok, %{rows: [_row], pagination_key: nil}} =
               Rest.list_event_markets(@credentials,
                 plug: responding([%{"symbol" => "KX-T1"}]),
                 retry_attempts: 0
               )
    end
  end
end
