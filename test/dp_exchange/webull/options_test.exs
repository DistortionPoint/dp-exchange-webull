defmodule DpExchange.Webull.OptionsTest do
  @moduledoc """
  The options surface: the contract list, and the three market-data endpoints that have
  their own paths.

  **The assertion that carries this file is the refusal.** Webull publishes a flat contract
  list and this package rebuilds the expiry × strike grid from it. A row whose expiry,
  strike or right cannot be read is refused, naming the keys the venue actually sent —
  because a dropped row leaves a chain with a hole in it that looks complete, and a caller
  walking strikes would never learn the strike was there.

  The second is what is **not** here: greeks. This venue publishes none, and computing them
  would need a rate and a volatility surface it does not publish either — every number
  would be this package's model presented as the venue's.
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
      send(test_pid, {:request, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # `option-contract-list.md:312` documents the response field as `expiration_date`, not
  # `expire_date` — that is the REQUEST parameter's name, on a different field entirely,
  # and reading the request's own name off the response found nothing on every row before
  # this fix.
  defp contract(overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => "AAPL250320C00100000",
        "expiration_date" => "2026-03-20",
        "strike_price" => "100",
        "direction" => "CALL",
        "multiplier" => "100"
      },
      overrides
    )
  end

  describe "get_option_chain/3 — the grid the venue flattened" do
    test "a call and a put at one strike land on the same row" do
      body = [
        contract(),
        contract(%{"direction" => "PUT", "symbol" => "AAPL250320P00100000"})
      ]

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert %Types.OptionChain{} = chain
      row = chain.expiries[~D[2026-03-20]][Decimal.new("100")]
      assert row.call.right == :call
      assert row.put.right == :put
    end

    test "a strike with one side keeps a nil on the other" do
      # A caller iterating strikes has to see that the put is missing. An absent key would
      # let it skip the strike entirely.
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding([contract()]),
                 retry_attempts: 0
               )

      row = chain.expiries[~D[2026-03-20]][Decimal.new("100")]
      assert row.call
      assert row.put == nil
    end

    test "two expiries are two keys" do
      body = [contract(), contract(%{"expiration_date" => "2026-06-19", "strike_price" => "120"})]

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Types.OptionChain.expiry_dates(chain) == [~D[2026-03-20], ~D[2026-06-19]]
    end

    test "the underlying price is nil, because this endpoint does not quote it" do
      # A price fetched separately and stamped on would be two observations at two times
      # presented as one, which is how a "delta-neutral" position turns out not to be.
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding([contract()]),
                 retry_attempts: 0
               )

      assert chain.underlying_price == nil
    end

    test "an unreadable row is refused, naming the keys the venue sent" do
      body = [Map.delete(contract(), "strike_price")]

      assert {:error, {:unreadable_option_contract, keys}} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert "expiration_date" in keys
      refute "strike_price" in keys
    end

    test "a right the venue words differently is still refused rather than defaulted" do
      # A put filed as a call is a position the opposite way round.
      body = [contract(%{"direction" => "SIDEWAYS"})]

      assert {:error, {:unreadable_option_contract, _keys}} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "the venue's single-letter rights are read" do
      body = [contract(%{"direction" => "C"}), contract(%{"direction" => "P"})]

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      row = chain.expiries[~D[2026-03-20]][Decimal.new("100")]
      assert row.call.right == :call
      assert row.put.right == :put
    end

    test "the fields the venue does not publish are nil, not false" do
      # `false` would say the venue told us it is not an index option. It said nothing.
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding([contract()]),
                 retry_attempts: 0
               )

      call = chain.expiries[~D[2026-03-20]][Decimal.new("100")].call
      assert call.index_option == nil
      assert call.mini == nil
      assert call.non_standard == nil
    end

    # `option-contract-list.md:357,362` names `settlement_method` and `expired_cycle`, not
    # `settlement_type`/`expiration_type` — those are `Core.Types.OptionContract`'s own
    # field names (freeform per-venue strings, not a shared enum), populated from the
    # venue's differently-spelled response fields.
    test "settlement_type and expiration_type come from settlement_method and expired_cycle" do
      body = [contract(%{"settlement_method" => "CASH", "expired_cycle" => "WEEKLY"})]

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      call = chain.expiries[~D[2026-03-20]][Decimal.new("100")].call
      assert call.settlement_type == "CASH"
      assert call.expiration_type == "WEEKLY"
    end

    test "pagination_key is followed to the end, bounded" do
      # `option-contract-list.md:167` documents `pagination_key`; `page_size` is not a
      # parameter this endpoint defines at all.
      plug = fn conn ->
        body =
          if String.contains?(conn.query_string || "", "pagination_key=page-2") do
            [contract(%{"symbol" => "AAPL250320P00100000", "direction" => "PUT"})]
          else
            %{
              "data" => [contract()],
              "pagination_key" => "page-2"
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @credentials, plug: plug, retry_attempts: 0)

      row = chain.expiries[~D[2026-03-20]][Decimal.new("100")]
      assert row.call.right == :call
      assert row.put.right == :put
    end

    test "the filters go to the venue rather than being applied here" do
      me = self()

      assert {:ok, _chain} =
               Rest.get_option_chain("AAPL", @credentials,
                 expiry: ~D[2026-03-20],
                 strike: Decimal.new("100"),
                 plug: capturing([contract()], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert path == "/trading/instruments/options/contracts/list"
      # `underlying_symbols` (plural, `option-contract-list.md:60`), `start_date`
      # (`:78`, "Exact expiration date"), and `strike_price_gte`/`strike_price_lte`
      # (`:127,136`) — an exact strike sent as the same value on both bounds of the
      # venue's range-only pair, not as a `strike_price` field this endpoint never
      # defines.
      assert query =~ "underlying_symbols=AAPL"
      assert query =~ "start_date=2026-03-20"
      assert query =~ "strike_price_gte=100"
      assert query =~ "strike_price_lte=100"
      refute query =~ "underlying_symbol="
      refute query =~ "expire_date="
      refute query =~ "strike_price="
    end
  end

  describe "get_option_expirations/3" do
    test "the distinct expiries come back earliest first" do
      body = [
        contract(%{"expiration_date" => "2026-06-19"}),
        contract(),
        contract(%{"direction" => "PUT"})
      ]

      assert {:ok, expiries} =
               Rest.get_option_expirations("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert expiries == [~D[2026-03-20], ~D[2026-06-19]]
    end

    test "an unreadable contract refuses here too, rather than yielding a short list" do
      # Silently dropping the row would return a list of expiries missing one the venue
      # listed, which reads as "the venue lists no such expiry".
      body = [Map.delete(contract(), "expiration_date")]

      assert {:error, {:unreadable_option_contract, _keys}} =
               Rest.get_option_expirations("AAPL", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "no contracts is an empty list, not an error" do
      assert {:ok, []} =
               Rest.get_option_expirations("AAPL", @credentials,
                 plug: responding([]),
                 retry_attempts: 0
               )
    end
  end

  describe "the fake" do
    test "the chain carries a strike with only one side" do
      assert {:ok, chain} = Fake.get_option_chain("AAPL", credentials: @credentials)
      row = chain.expiries[~D[2026-06-19]][Decimal.new("120")]
      assert row.call
      assert row.put == nil
    end

    test "the underlying price stays nil, as it does in the package" do
      assert {:ok, chain} = Fake.get_option_chain("AAPL", credentials: @credentials)
      assert chain.underlying_price == nil
    end

    test "the expiries are the chain's" do
      assert {:ok, expiries} = Fake.get_option_expirations("AAPL", credentials: @credentials)
      assert expiries == [~D[2026-03-20], ~D[2026-06-19]]
    end

    # The options endpoints sign like every other call on this venue, so the fake has to
    # refuse without credentials the way `Rest` does. They are outside
    # `Core.AdapterContract`'s hardcoded `@credentialed` list, so assertion 17 never asks.
    test "the options callbacks need credentials, as the real venue does" do
      assert Fake.get_option_chain("AAPL") == {:error, {:missing_credentials, :webull}}
      assert Fake.get_option_expirations("AAPL") == {:error, {:missing_credentials, :webull}}
    end

    test "greeks refuse, because the venue publishes none" do
      assert {:error, :not_supported} = Fake.get_option_greeks("AAPL250320C00100000")
      assert {:error, :not_supported} = DpExchange.Webull.get_option_greeks("X", [])
    end
  end

  describe "the facade reaches the venue" do
    test "get_option_chain/2 delegates" do
      assert {:ok, chain} =
               DpExchange.Webull.get_option_chain("AAPL",
                 credentials: @credentials,
                 plug: responding([contract()]),
                 retry_attempts: 0
               )

      assert chain.underlying == "AAPL"
    end

    test "get_option_expirations/2 delegates" do
      assert {:ok, [~D[2026-03-20]]} =
               DpExchange.Webull.get_option_expirations("AAPL",
                 credentials: @credentials,
                 plug: responding([contract()]),
                 retry_attempts: 0
               )
    end
  end
end
