defmodule DpExchange.Webull.ReferenceDataTest do
  @moduledoc """
  Fundamentals, screeners and news — thirty endpoints under three shapes.

  **The parameter table is the assertion.** Every fundamentals endpoint takes `symbol` and
  `category` and differs only in what it adds, and a parameter that belongs to one must not
  leak into another: `type` and `count` are real on a balance sheet and unknown on a dividend
  calendar, and an unknown parameter is at best ignored and at worst a refusal — neither of
  which tells the caller which happened.

  Two mappings are stated rather than guessed. **`fiscal_period` goes through the venue's own
  legend** (`0=FY, 1=Q1 .. 4=Q4`; a code outside it is `nil`, the raw integer stays in
  `line_items`). And a screener's **rank is the position the venue returned the row in** —
  this package publishes no ranking of its own, because two venues' "top movers" answer
  different questions.
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

  # `GET /market-data/news/stock-news/list` (`openapi/list-stock-news.md`, `StockNewsResultVo`):
  # `{symbol, data: [NewsItemVo], pagination_key}`. A row carries the page's own example
  # values unless a test overrides one.
  defp news_row(overrides) do
    Map.merge(
      %{
        "news_id" => "20261008-001",
        "title" => "NVIDIA Announces New AI Chip",
        "summary" => "NVIDIA unveiled its next-generation AI chip at GTC.",
        "source" => "Reuters",
        "url" => "https://www.example.com/news/nvidia-ai-chip",
        "publish_time" => "2026-10-08T09:30:00.000-04:00",
        "sentiment" => "POSITIVE",
        "related_symbols" => ["NVDA", "AMD"]
      },
      overrides
    )
  end

  defp news_body(rows), do: %{"symbol" => "TSLA", "data" => rows}

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

    test "fiscal_period 3 is read through the venue's own legend as Q3" do
      # The legend (`0=FY, 1=Q1 .. 4=Q4`) is the venue's, so the label is its fiscal quarter,
      # not a calendar one; the raw integer stays in `line_items`.
      body = [%{"fiscal_period" => 3, "end_date" => "2025-09-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :cash_flow, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == "Q3"
      assert statement.line_items["fiscal_period"] == 3
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

    test "news is a GET of the stock-news list, one request per symbol, with the filters" do
      me = self()

      assert {:ok, _news} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 sentiment: "POSITIVE",
                 plug: capturing(news_body([news_row(%{})]), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/market-data/news/stock-news/list", query, ""}
      params = URI.decode_query(query)

      assert params == %{"symbol" => "TSLA", "category" => "US_STOCK", "sentiment" => "POSITIVE"}
    end

    test "news without symbols is refused" do
      assert {:error, :symbols_required} = Rest.get_news(@credentials, [])
    end

    test "the venue's fields land on the item, and publish_time is converted to UTC" do
      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: responding(news_body([news_row(%{})])),
                 retry_attempts: 0
               )

      assert item.id == "20261008-001"
      assert item.headline == "NVIDIA Announces New AI Chip"
      assert item.summary == "NVIDIA unveiled its next-generation AI chip at GTC."
      assert item.source == "Reuters"
      assert item.url == "https://www.example.com/news/nvidia-ai-chip"
      assert item.published_at == ~U[2026-10-08 13:30:00.000Z]
      assert item.symbols == ["TSLA", "NVDA", "AMD"]
      assert item.provider == :webull
    end

    test "a field the venue leaves out is nil, not filled in" do
      row = %{"news_id" => "n-2"}

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: responding(news_body([row])),
                 retry_attempts: 0
               )

      assert %{headline: nil, summary: nil, url: nil, source: nil, published_at: nil} = item
      assert item.symbols == ["TSLA"]
    end

    test "an item returned for two of the symbols asked about appears once, with both" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        shared = news_row(%{"news_id" => "shared", "related_symbols" => []})
        own = news_row(%{"news_id" => "own-" <> conn.params["symbol"], "related_symbols" => []})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(news_body([shared, own])))
      end

      assert {:ok, items} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL", "GOOG"],
                 plug: plug,
                 retry_attempts: 0
               )

      assert Enum.map(items, & &1.id) == ["shared", "own-AAPL", "own-GOOG"]
      assert Enum.find(items, &(&1.id == "shared")).symbols == ["AAPL", "GOOG"]
    end

    test "an item with no news_id refuses the whole read" do
      rows = [news_row(%{}), Map.delete(news_row(%{}), "news_id")]

      assert {:error, {:missing_required_field, :id}} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: responding(news_body(rows)),
                 retry_attempts: 0
               )
    end

    test "a publish_time that is not a timestamp refuses the whole read" do
      assert {:error, {:unparseable_venue_timestamp, "yesterday"}} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: responding(news_body([news_row(%{"publish_time" => "yesterday"})])),
                 retry_attempts: 0
               )
    end

    test "related_symbols that are not tickers refuse the read" do
      for bad <- ["NVDA", ["[\"NVDA\",\"AMD\"]"], [%{}], [""]] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_news(@credentials,
                   symbols: ["TSLA"],
                   plug: responding(news_body([news_row(%{"related_symbols" => bad})])),
                   retry_attempts: 0
                 )
      end
    end

    test "a body without the data array is not a news page" do
      for body <- [%{"symbol" => "TSLA"}, [], %{"data" => "x"}, %{"data" => [1]}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_news(@credentials,
                   symbols: ["TSLA"],
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end
    end

    test "a category or sentiment outside the page's enum is refused before a request" do
      exploding = fn _conn -> raise "must not reach the venue" end

      for opts <- [[category: "EU"], [sentiment: "BULL"], [sentiment: 5], [category: %{}]] do
        assert {:error, {:invalid_option, _key, _value}} =
                 Rest.get_news(@credentials, [symbols: ["TSLA"], plug: exploding] ++ opts)
      end
    end

    test "HK_STOCK is the other category the page lists" do
      me = self()

      assert {:ok, []} =
               Rest.get_news(@credentials,
                 symbols: ["00700"],
                 category: :HK_STOCK,
                 plug: capturing(news_body([]), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, ""}
      assert URI.decode_query(query)["category"] == "HK_STOCK"
    end
  end

  describe "get_news/2 follows the venue's cursor" do
    # `pages` maps the cursor a request carries (`nil` for the first) to `{ids, next}`;
    # `next` is the cursor the page hands back, or `:none` for a last page.
    defp paged(pages, test_pid) do
      fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:cursor, conn.params["pagination_key"]})
        {ids, next} = Map.fetch!(pages, conn.params["pagination_key"])
        rows = Enum.map(ids, &news_row(%{"news_id" => &1, "related_symbols" => []}))
        page = news_body(rows)
        body = if next == :none, do: page, else: Map.put(page, "pagination_key", next)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end
    end

    @three_pages %{
      nil => {["a", "b"], "p2"},
      "p2" => {["c", "d"], "p3"},
      "p3" => {["e"], :none}
    }

    test "without a limit the feed is read to its end, in the venue's order" do
      assert {:ok, items} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: paged(@three_pages, self()),
                 retry_attempts: 0
               )

      assert Enum.map(items, & &1.id) == ["a", "b", "c", "d", "e"]
      assert_receive {:cursor, nil}
      assert_receive {:cursor, "p2"}
      assert_receive {:cursor, "p3"}
    end

    test "a limit is honoured exactly and stops reading once met" do
      assert {:ok, items} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 limit: 3,
                 plug: paged(@three_pages, self()),
                 retry_attempts: 0
               )

      assert Enum.map(items, & &1.id) == ["a", "b", "c"]
      assert_receive {:cursor, nil}
      assert_receive {:cursor, "p2"}
      refute_receive {:cursor, "p3"}, 500
    end

    test "a limit larger than the feed returns what the feed has" do
      assert {:ok, items} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 limit: 50,
                 plug: paged(@three_pages, self()),
                 retry_attempts: 0
               )

      assert length(items) == 5
    end

    test "an empty cursor is the end of the feed" do
      pages = %{nil => {["a"], ""}}

      assert {:ok, [%{id: "a"}]} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: paged(pages, self()),
                 retry_attempts: 0
               )
    end

    test "a feed with a cursor at every page hits the cap and is refused, not truncated" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        next = (conn.params["pagination_key"] || "") <> "x"
        body = Map.put(news_body([news_row(%{"news_id" => next})]), "pagination_key", next)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:error, :history_truncated} =
               Rest.get_news(@credentials, symbols: ["TSLA"], plug: plug, retry_attempts: 0)
    end

    test "a cursor that is not text is refused" do
      body = Map.put(news_body([news_row(%{})]), "pagination_key", %{"a" => 1})

      assert {:error, :unexpected_pagination_key} =
               Rest.get_news(@credentials,
                 symbols: ["TSLA"],
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a limit that is not a positive integer is refused before a request" do
      exploding = fn _conn -> raise "must not reach the venue" end

      for bad <- [0, -1, "5", 1.5, :all] do
        assert {:error, {:invalid_option, :limit, ^bad}} =
                 Rest.get_news(@credentials, symbols: ["TSLA"], limit: bad, plug: exploding)
      end
    end
  end

  describe "a row that cannot supply its own identity refuses the read, never given an empty one" do
    # `|| ""` satisfied the contract's non-nil requirement while saying nothing. It is worse
    # than a `nil`: a `nil` is detectable and an empty string is a value, so a consumer
    # keying coverage by symbol gets a live entry named "". Dropping the row instead left a
    # hole in the ranking, so the read is refused as a whole.

    test "a screener row with no symbol refuses the ranking" do
      rows = [%{"symbol" => "AAPL"}, %{"close" => "1"}, %{"symbol" => "MSFT"}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end

    test "a screener row whose symbol is not text refuses the ranking" do
      rows = [%{"symbol" => 123}, %{"symbol" => %{"x" => 1}}, %{"symbol" => "MSFT"}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end

    test "a fully named ranking keeps the venue's own positions as ranks" do
      rows = [%{"symbol" => "AAPL"}, %{"symbol" => "MSFT"}]

      assert {:ok, [first, second]} =
               Rest.get_screener("gainers_losers", @credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert {first.rank, second.rank} == {1, 2}
    end

    # `:id` is the venue's own `news_id`, never a symbol used as a stand-in: the old
    # fallback on a JSON row was `value(row, ["id", "news_id"]) || value(row, ["symbol"])
    # || ""`, and a ticker as an item id is the worst of the three — it looks like an id
    # and collides for every item about the same symbol.
    test "the news item's id is the venue's news_id, never a symbol" do
      row = news_row(%{"news_id" => "n-42", "symbol" => "AAPL", "id" => "other"})

      assert {:ok, [item]} =
               Rest.get_news(@credentials,
                 symbols: ["AAPL"],
                 plug: responding(news_body([row])),
                 retry_attempts: 0
               )

      assert item.id == "n-42"
    end

    test "a watchlist row with no id refuses the whole listing, it is not dropped" do
      rows = [%{"watchlist_id" => "w-1", "name" => "Mine"}, %{"name" => "nameless"}]

      assert {:error, {:missing_required_field, :id}} =
               Rest.list_watchlists(@credentials, plug: responding(rows), retry_attempts: 0)
    end
  end

  describe "get_screener/3" do
    test "seven screeners are published" do
      assert length(Rest.screeners()) == 7
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

    test "a pagination_key that always advances is stopped, not followed forever" do
      for name <- ["market_sectors", "market_sector"] do
        counter = :counters.new(1, [])

        plug = fn conn ->
          :counters.add(counter, 1, 1)
          page = :counters.get(counter, 1)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "data" => [%{"sector_name" => "T"}],
              "pagination_key" => "p-#{page}"
            })
          )
        end

        assert {:error, :history_truncated} =
                 Rest.get_screener(name, @credentials,
                   sector_id: "1",
                   plug: plug,
                   retry_attempts: 0
                 )

        assert :counters.get(counter, 1) in 2..500
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

    test "the fake's statement labels the fiscal period through the venue's legend" do
      assert {:ok, [statement]} =
               Fake.get_financials("AAPL", :balance_sheet, credentials: @credentials)

      assert statement.fiscal_period == "FY"
    end

    # Tick AK: news is the venue's itemised article list, so `source` is the publisher an
    # article came from and `provider` names the venue; the old LLM summary had no publisher.
    test "the fake's news names the venue as provider and carries a publisher, link and time" do
      assert {:ok, [item]} = Fake.get_news(credentials: @credentials, symbols: ["AAPL"])
      assert item.provider == :webull
      assert is_binary(item.source) and item.source != ""
      assert is_binary(item.headline) and is_binary(item.url)
      assert %DateTime{} = item.published_at
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

      # A screener the venue publishes: an unknown one is refused before credentials, as
      # `Rest.get_screener/3` does, so "nope" here would not be proving the credential check.
      assert Fake.get_screener("top_actives") == {:error, {:missing_credentials, :webull}}
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
                 base ++ [symbols: ["AAPL"], plug: responding(news_body([news_row(%{})]))]
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
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == "FY2026"
    end

    test "a numeric-string fiscal period goes through the legend, not through as a label" do
      body = [%{"fiscal_period" => "0", "end_date" => "2025-12-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert statement.fiscal_period == "FY"
    end

    test "a fiscal period outside the legend is nil, and the integer is still readable" do
      body = [%{"fiscal_period" => 9, "end_date" => "2025-12-27"}]

      assert {:ok, [statement]} =
               Rest.get_financials("AAPL", :balance_sheet, @credentials,
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
                 plug: capturing(news_body([news_row(%{})]), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, ""}
      assert URI.decode_query(query)["symbol"] == "AAPL"
      refute_receive {:request, _method, _path, _query, _raw}, 500
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
