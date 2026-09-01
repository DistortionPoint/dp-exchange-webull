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

      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :dividend,
                 plug: capturing([%{"ex_dividend_date" => "2026-08-10", "amount" => "0.25"}], me),
                 retry_attempts: 0
               )

      assert event.kind == :dividend
      assert event.ex_date == ~D[2026-08-10]
      assert Decimal.equal?(event.amount, Decimal.new("0.25"))

      assert_receive {:request, "GET", "/market-data/fundamentals/dividend-calendars/list", _q,
                      _r}

      refute_receive {:request, "GET", _other, _q2, _r2}
    end

    test "confirmed is nil, because the venue publishes no such flag" do
      # `true` would claim a date is final when an earnings date routinely is not.
      assert {:ok, [event]} =
               Rest.get_corporate_events(@credentials,
                 symbol: "AAPL",
                 kind: :earnings,
                 plug: responding([%{"announce_date" => "2026-08-01"}]),
                 retry_attempts: 0
               )

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
    test "a filing points at a url and nothing follows it" do
      body = [
        %{
          "id" => "f-1",
          "form_type" => "10-Q",
          "title" => "Quarterly report",
          "url" => "https://example.invalid/f-1"
        }
      ]

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
                 plug: capturing([%{"title" => "x"}], me),
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

    test "the source is the venue, because the summary is generated" do
      # The vendor's own description is "invokes LLM to generate news summaries". Naming a
      # publisher would attribute a paraphrase to them.
      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: responding([%{"title" => "x", "summary" => "y"}]),
                 retry_attempts: 0
               )

      assert item.source == "webull"
      assert item.symbols == ["AAPL"]
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
  end

  describe "the fake and the facade" do
    test "the fake refuses what the package refuses" do
      assert {:error, :symbol_required} = Fake.get_corporate_events()
      assert {:error, :symbols_required} = Fake.get_news()
      assert {:error, {:unknown_screener, "nope"}} = Fake.get_screener("nope")
    end

    test "the fake's statement keeps the integer fiscal period" do
      assert {:ok, [statement]} = Fake.get_financials("AAPL", :balance_sheet)
      assert statement.fiscal_period == "FY"
    end

    test "the fake's news names the venue as the source" do
      assert {:ok, [item]} = Fake.get_news(symbols: ["AAPL"])
      assert item.source == "webull"
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
               DpExchange.Webull.get_filings("AAPL", base ++ [plug: responding([%{}])])

      assert {:ok, [_item]} =
               DpExchange.Webull.get_news(base ++ [symbols: ["AAPL"], plug: responding([%{}])])

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
      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials,
                 plug: responding([%{"id" => "f-1"}]),
                 retry_attempts: 0
               )

      assert filing.filed_at == nil
    end

    test "a filing that carries one is read" do
      body = [%{"id" => "f-1", "time" => "2026-08-31T10:15:30.691Z"}]

      assert {:ok, [filing]} =
               Rest.get_filings("AAPL", @credentials, plug: responding(body), retry_attempts: 0)

      assert filing.filed_at.year == 2026
    end

    test "a single symbol reaches get_news/2 as a one-element list" do
      me = self()

      assert {:ok, _news} =
               Rest.get_news(@credentials,
                 symbols: "AAPL",
                 plug: capturing([%{}], me),
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
