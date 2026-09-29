defmodule DpExchange.Webull.OrderMappingTest do
  @moduledoc """
  What a caller is handed when the venue sends a word this package does not know.

  Every one of these assertions is that the answer is `nil`. The failure this guards is the
  one §0 names: a `SIDEWAYS` becoming `:buy` because `:buy` was the nearest atom to hand
  stays plausible all the way to whatever reads it.

  It also covers the refusal branches, because a venue that answers `400` with a message is
  saying something different from a venue that times out, and a caller retrying the first is
  retrying something that will refuse again.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

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

  # `/trading/orders/get` returns a GROUP — `{client_order_id, combo_order_id, combo_type,
  # orders: [...]}` (order-detail.md:163,182) — never a flat order row at the top. This
  # fixture used to be the bare row itself, which pinned the bug `to_order/1` had rather
  # than the vendor's documented shape: `total_quantity` (not `qty`) and `status` (not
  # `order_status`) are this leg's own field names.
  defp row(overrides) do
    Map.merge(
      %{
        "client_order_id" => "abc",
        "symbol" => "BTCUSD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "GTC",
        "status" => "PENDING",
        "total_quantity" => "0.5"
      },
      overrides
    )
  end

  defp group(overrides), do: %{"combo_type" => "NORMAL", "orders" => [row(overrides)]}

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp fetch(overrides) do
    {:ok, order} =
      Rest.get_order(@credentials, "abc",
        plug: responding([group(overrides)]),
        account_id: @account,
        retry_attempts: 0
      )

    order
  end

  describe "the venue's vocabulary, and everything outside it" do
    for {venue, expected} <- [{"BUY", :buy}, {"SELL", :sell}] do
      test "side #{venue} is #{expected}" do
        assert fetch(%{"side" => unquote(venue)}).side == unquote(expected)
      end
    end

    test "a side this package does not know is nil" do
      assert fetch(%{"side" => "SIDEWAYS"}).side == nil
    end

    # W1: all five order types this package's own `@order_type_names` forward-encodes,
    # and that `capabilities/0` declares supported, must decode back. Before the fix,
    # `STOP_LOSS` and `TRAILING_STOP_LOSS` silently answered `nil` here despite being
    # genuinely real values this package itself sends on `place_order/3`.
    for {venue, expected} <- [
          {"MARKET", :market},
          {"LIMIT", :limit},
          {"STOP_LOSS", :stop},
          {"STOP_LOSS_LIMIT", :stop_limit},
          {"TRAILING_STOP_LOSS", :trailing_stop}
        ] do
      test "order type #{venue} is #{expected}" do
        assert fetch(%{"order_type" => unquote(venue)}).order_type == unquote(expected)
      end
    end

    test "an order type this package does not know is nil" do
      # "TRAILING_STOP" (no _LOSS) is not a real Webull value — the real one is
      # TRAILING_STOP_LOSS, covered above. This exercises the genuine unknown-value path.
      assert fetch(%{"order_type" => "TRAILING_STOP"}).order_type == nil
    end

    test "a missing order type is nil rather than a default" do
      assert fetch(%{"order_type" => nil}).order_type == nil
    end

    # W1: all five TIFs this package's own `@tif_names` forward-encodes, and that
    # `capabilities/0` declares supported, must decode back. Before the fix, `GTD` and
    # `FOK` silently answered `nil` here.
    for {venue, expected} <- [
          {"IOC", :ioc},
          {"DAY", :day},
          {"GTC", :gtc},
          {"GTD", :gtd},
          {"FOK", :fok}
        ] do
      test "time in force #{venue} is #{expected}" do
        assert fetch(%{"time_in_force" => unquote(venue)}).time_in_force == unquote(expected)
      end
    end

    test "a time in force this package does not know is nil" do
      # "GFD" is a real Robinhood value, not one Webull publishes — genuine unknown-value
      # path, not one of the five this package encodes.
      assert fetch(%{"time_in_force" => "GFD"}).time_in_force == nil
    end

    # `order-detail.md:215`'s documented `status` enum is exactly PENDING, SUBMITTED,
    # CANCELLED, FILLED, FAILED, PARTIAL_FILLED — `WORKING`, single-`L` `CANCELED`,
    # `REJECTED` and `EXPIRED` are not members of it and are covered by the
    # "not documented" test below instead of asserted as mapped values here.
    # `PARTIAL_FILLED` is Core's own `:partially_filled`, not `:open` — the two are
    # different claims (some of the order filled vs. none of it) and this package sent the
    # wrong one for every partially filled order read back before the fix. `FAILED` maps
    # to `:rejected` on the vendor's own equivalence ("Indicates a failed order, such as
    # REJECTED").
    for {venue, expected} <- [
          {"PENDING", :pending},
          {"PARTIAL_FILLED", :partially_filled},
          {"FILLED", :filled},
          {"CANCELLED", :cancelled},
          {"FAILED", :rejected}
        ] do
      test "status #{venue} is #{expected}" do
        assert fetch(%{"status" => unquote(venue)}).status == unquote(expected)
      end
    end

    # `SUBMITTED` is a real vendor value with no stated equivalence to any status this
    # package's own `Core.Types.Order.status/0` names ("submitted to the exchange or
    # webull" says nothing about whether the order is working) — `nil`, not a guess at
    # `:open`. `WORKING`, `CANCELED` (single `L`) and `EXPIRED` were never in the
    # documented enum at all and get the same answer for not being provable.
    for venue <- ["SUBMITTED", "WORKING", "CANCELED", "REJECTED", "EXPIRED"] do
      test "status #{venue} is not documented for this endpoint, so nil" do
        assert fetch(%{"status" => unquote(venue)}).status == nil
      end
    end

    test "a missing symbol leaves the symbol nil rather than crashing" do
      assert fetch(%{"symbol" => nil}).symbol == nil
    end

    # `stop_price` was missing from `to_order/1` entirely: `Core.Types.Order` carries the
    # field, and this package's own `place_order/3`/`replace_order/4` both send it for a
    # STOP_LOSS or STOP_LOSS_LIMIT order, but reading one back always answered `nil`
    # regardless of what the venue reported.
    test "a stop order's trigger price round-trips through get_order" do
      assert fetch(%{"order_type" => "STOP_LOSS", "stop_price" => "175.00"}).stop_price ==
               Decimal.new("175.00")
    end

    test "the camelCase form decodes too, matching every other field on this row" do
      assert fetch(%{"order_type" => "STOP_LOSS", "stopPrice" => "175.00"}).stop_price ==
               Decimal.new("175.00")
    end

    test "an order with no stop leaves stop_price nil rather than 0" do
      assert fetch(%{"order_type" => "LIMIT"}).stop_price == nil
    end
  end

  describe "what the venue said when it said no" do
    test "a 400 carrying a message keeps the message" do
      assert {:refused, {:venue_error, 400, "insufficient buying power"}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"msg" => "insufficient buying power"}, 400),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a 403 carrying only a code keeps the code" do
      assert {:refused, {:venue_error, 403, "TRADE_NOT_PERMITTED"}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"code" => "TRADE_NOT_PERMITTED"}, 403),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a refusal that explains nothing still says WHICH refusal it was" do
      assert {:refused, {:venue_error, 401}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding([], 401),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "a 500 is an error, because nobody refused anything" do
      assert {:error, {:exchange_error, :webull, message}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: responding(%{"msg" => "boom"}, 500),
                 account_id: @account,
                 retry_attempts: 0
               )

      # The HTTP layer classifies 5xx before this module sees it; either way it is an error
      # and carries the status.
      assert message =~ "500"
    end

    test "a body that is not JSON at all does not crash the refusal reader" do
      plug = fn conn -> Plug.Conn.resp(conn, 400, "<html>gateway</html>") end

      assert {:refused, {:venue_error, 400}} =
               Rest.cancel_order(@credentials, "abc",
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )
    end
  end

  describe "reading an order the venue did not send" do
    test "an empty list is an unreadable response, not a missing order" do
      # `[]` here means "the venue answered about no orders". Returning `{:ok, nil}` would
      # make a caller's `nil` check the only thing between that and a phantom order.
      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@credentials, "abc",
                 plug: responding([]),
                 account_id: @account,
                 retry_attempts: 0
               )
    end

    test "get_order without an account is refused before the call" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, :account_id_required} =
               Rest.get_order(@credentials, "abc", plug: exploding, retry_attempts: 0)
    end

    test "get_orders without an account is refused before the call" do
      exploding = fn _conn -> raise "must not call the venue without an account" end

      assert {:error, :account_id_required} =
               Rest.get_orders(@credentials, plug: exploding, retry_attempts: 0)
    end

    # `order-open.md:46,554` and `order-history.md:66` document `pagination_key`, never a
    # `page_size` — this used to send `opts[:limit]` as `page_size` on both list endpoints,
    # a parameter neither one defines. `opts[:limit]` is no longer read here at all; it is
    # asserted absent from the wire rather than asserted present under any name.
    test "opts[:limit] is not sent — this endpoint has no page_size parameter" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 limit: 25,
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      refute query =~ "page_size"
      refute query =~ "limit"
    end

    # `order-history.md:47,58` documents `start_time`/`end_time` on the HISTORY endpoint
    # only, in the venue's `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` format — sending them on
    # `/orders/open-orders/list` too would ask that endpoint a parameter it does not
    # define, which is why `history: true` is required here.
    test "history: true sends opts[:since]/opts[:until] as start_time/end_time" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path, :query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 history: true,
                 since: ~U[2026-01-01 00:00:00.000Z],
                 until: ~U[2026-01-31 23:59:59.000Z],
                 plug: plug,
                 account_id: @account,
                 retry_attempts: 0
               )

      assert_receive {:path, path, :query, query}
      assert path == "/trading/orders/historical-orders/list"
      assert query =~ "start_time=2026-01-01T00%3A00%3A00.000Z"
      assert query =~ "end_time=2026-01-31T23%3A59%3A59.000Z"
    end

    test "pagination_key is followed to the end, bounded" do
      # Same convention `order_book_test.exs`'s `get_symbols/2` pagination tests use:
      # branch on the query string rather than process-bound state, because the plug may
      # run outside this test process.
      plug = fn conn ->
        body =
          if String.contains?(conn.query_string || "", "pagination_key=page-2") do
            %{"data" => [group(%{"client_order_id" => "c-2"})]}
          else
            %{"data" => [group(%{"client_order_id" => "c-1"})], "pagination_key" => "page-2"}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, [%{id: "c-1"}, %{id: "c-2"}]} =
               Rest.get_orders(@credentials, plug: plug, account_id: @account, retry_attempts: 0)
    end
  end
end
