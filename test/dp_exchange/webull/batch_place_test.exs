defmodule DpExchange.Webull.BatchPlaceTest do
  @moduledoc """
  `place_orders/3` — one request, and the venue's two limits.

  **A batch is not `place_order/3` in a loop.** The venue accepts it as one request, and a
  caller that looped would reconcile N outcomes instead of reading one response. The
  reconciliation is what goes wrong when the third of five fails.

  **The result is per order, because a partial batch is the normal shape.** The venue
  validates each and returns each; a package that collapsed that into ok-or-error would let
  a caller believe "the batch failed" while holding four positions it does not know about.

  Both caps come from the vendor's own page: **50 orders** and **equities only**. Both are
  enforced before the request — over the cap is refused rather than split, because splitting
  turns one atomic request into several and undoes the only reason to call this.
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

  defp order(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :day,
        quantity: Decimal.new("10"),
        price: Decimal.new("180"),
        instrument_type: :equity
      },
      overrides
    )
  end

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
      send(test_pid, {:request, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "one request" do
    test "every order goes in a single body under the venue's own key" do
      me = self()

      assert {:ok, _results} =
               Rest.place_orders(@credentials, [order(), order(%{symbol: "MSFT"})],
                 account_id: "acct-1",
                 plug: capturing([%{"order_id" => "1"}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, raw}
      assert path == "/trading/orders/batch-place"

      body = Jason.decode!(raw)
      assert body["account_id"] == "acct-1"
      assert length(body["batch_orders"]) == 2
      assert Enum.map(body["batch_orders"], & &1["symbol"]) == ["AAPL", "MSFT"]
    end

    test "each order carries its own client order id" do
      # The venue requires one per order and requires them unique per account.
      me = self()

      assert {:ok, _results} =
               Rest.place_orders(@credentials, [order(), order(%{symbol: "MSFT"})],
                 account_id: "acct-1",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, raw}
      ids = Jason.decode!(raw)["batch_orders"] |> Enum.map(& &1["client_order_id"])
      assert Enum.all?(ids, &is_binary/1)
      assert length(Enum.uniq(ids)) == 2
    end

    test "a caller's own id is kept" do
      me = self()

      assert {:ok, _results} =
               Rest.place_orders(@credentials, [order(%{client_order_id: "mine-1"})],
                 account_id: "acct-1",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, raw}
      assert Jason.decode!(raw)["batch_orders"] |> hd() |> Map.get("client_order_id") == "mine-1"
    end
  end

  describe "the venue's limits, enforced before the request" do
    test "an empty batch is refused" do
      assert {:error, :empty_batch} = Rest.place_orders(@credentials, [], account_id: "acct-1")
    end

    test "fifty-one is refused rather than split" do
      # Splitting turns one atomic request into several and undoes the only reason to call
      # this.
      orders = for i <- 1..51, do: order(%{symbol: "SYM#{i}"})

      assert {:error, {:batch_too_large, 51, 50}} =
               Rest.place_orders(@credentials, orders, account_id: "acct-1")
    end

    test "fifty is allowed" do
      orders = for i <- 1..50, do: order(%{symbol: "SYM#{i}"})

      assert {:ok, _results} =
               Rest.place_orders(@credentials, orders,
                 account_id: "acct-1",
                 plug: responding([]),
                 retry_attempts: 0
               )
    end

    test "a non-equity order is refused by index, so a caller knows which of fifty" do
      orders = [order(), order(%{instrument_type: :crypto}), order()]

      assert {:error, {:batch_instrument_not_supported, 1, :crypto}} =
               Rest.place_orders(@credentials, orders, account_id: "acct-1")
    end

    test "an order outside the venue's matrix is refused by index too" do
      # The reason names both the position and the venue's own objection — fill-or-kill is
      # not in this venue's equity matrix, and a caller with fifty orders needs to know which.
      orders = [order(), order(%{time_in_force: :fok})]

      assert {:error, {:batch_order_rejected, 1, reason}} =
               Rest.place_orders(@credentials, orders, account_id: "acct-1")

      assert reason == {:unsupported_order_combination, :equity, :limit, :fok}
    end

    test "the account id is required, as it is on the single-order call" do
      assert {:error, :account_id_required} = Rest.place_orders(@credentials, [order()], [])
    end
  end

  describe "the result is per order" do
    test "a partial batch comes back whole, refusals included" do
      body = [
        %{"order_id" => "o-1", "symbol" => "AAPL"},
        %{"code" => "INSUFFICIENT_BUYING_POWER", "symbol" => "MSFT"}
      ]

      assert {:ok, [placed, refused]} =
               Rest.place_orders(@credentials, [order(), order(%{symbol: "MSFT"})],
                 account_id: "acct-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert placed["order_id"] == "o-1"
      assert refused["code"] == "INSUFFICIENT_BUYING_POWER"
    end

    test "a venue refusal of the whole batch is a refusal, not a partial result" do
      # The vendor notes the endpoint is not available to every client, so this can mean the
      # account is not entitled rather than that the batch was wrong.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, Jason.encode!(%{"code" => "NOT_ENTITLED"}))
      end

      assert {:refused, _reason} =
               Rest.place_orders(@credentials, [order()],
                 account_id: "acct-1",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "the fake and the facade" do
    test "the fake holds the same limits" do
      assert {:error, :account_id_required} = Fake.place_orders(%{}, [order()], [])
      assert {:error, :empty_batch} = Fake.place_orders(%{}, [], account_id: "a")

      big = for i <- 1..51, do: order(%{symbol: "SYM#{i}"})
      assert {:error, {:batch_too_large, 51, 50}} = Fake.place_orders(%{}, big, account_id: "a")

      assert {:error, {:batch_instrument_not_supported, 0, :crypto}} =
               Fake.place_orders(%{}, [order(%{instrument_type: :crypto})], account_id: "a")
    end

    test "the fake's batch is partial" do
      assert {:ok, [first, second]} =
               Fake.place_orders(%{}, [order(), order()], account_id: "a")

      assert first["order_id"]
      assert second["code"]
    end

    test "the facade delegates" do
      assert {:ok, _results} =
               DpExchange.Webull.place_orders(@credentials, [order()],
                 account_id: "acct-1",
                 plug: responding([]),
                 retry_attempts: 0
               )
    end
  end
end
