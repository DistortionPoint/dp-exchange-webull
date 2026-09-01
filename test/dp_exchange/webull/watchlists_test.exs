defmodule DpExchange.Webull.WatchlistsTest do
  @moduledoc """
  Watchlists — eight endpoints, and three of them answer with a boolean.

  **`{"success": false}` is a 200 that did nothing.** Every watchlist write on this venue
  answers with that field rather than an error status, so reporting the HTTP result as
  success is the failure these endpoints invite.

  Two absences are asserted rather than filled in. **`symbols` is `nil` on a listing row** —
  the listing names watchlists and does not read membership, and `[]` would say the
  watchlist is empty. **`name` is `nil` on a membership read** — that endpoint does not
  return it, and fetching it separately would put a name from a moment ago beside a
  membership from now.

  And **creating with members is two requests**: where the second fails the watchlist exists
  and is empty, which is why that case returns an error carrying its id rather than an
  `{:ok, watchlist}` a caller would read as complete.
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

  defp ok, do: responding([%{"success" => true}])

  describe "reading" do
    test "a listing row has a name and no membership" do
      body = [%{"watchlist_id" => "wl-1", "name" => "My Tech Stocks", "sort" => 1}]

      assert {:ok, [watchlist]} =
               Rest.list_watchlists(@credentials, plug: responding(body), retry_attempts: 0)

      assert %Types.Watchlist{id: "wl-1", name: "My Tech Stocks"} = watchlist
      # `nil` is "not asked". `[]` would say this watchlist is empty.
      assert watchlist.symbols == nil
    end

    test "a membership read has symbols and no name" do
      body = [
        %{
          "watchlist_id" => "wl-1",
          "instruments" => [
            %{"symbol" => "AAPL", "instrument_id" => "913256135"},
            %{"symbol" => "GOOG", "instrument_id" => "913256136"}
          ]
        }
      ]

      assert {:ok, watchlist} =
               Rest.get_watchlist("wl-1", @credentials, plug: responding(body), retry_attempts: 0)

      assert watchlist.symbols == ["AAPL", "GOOG"]
      assert watchlist.name == nil
    end

    test "the membership read sends the id as a query parameter" do
      me = self()

      assert {:ok, _watchlist} =
               Rest.get_watchlist("wl-1", @credentials,
                 plug: capturing([%{"watchlist_id" => "wl-1"}], me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/market-data/watchlists/instruments/list"
      assert query =~ "watchlist_id=wl-1"
    end

    test "an instrument row with no symbol is dropped rather than becoming nil" do
      body = [%{"watchlist_id" => "wl-1", "instruments" => [%{"instrument_id" => "1"}]}]

      assert {:ok, watchlist} =
               Rest.get_watchlist("wl-1", @credentials, plug: responding(body), retry_attempts: 0)

      assert watchlist.symbols == []
    end
  end

  describe "creating" do
    test "an empty symbol list makes one request" do
      me = self()

      assert {:ok, watchlist} =
               Rest.create_watchlist("Empty", [], @credentials,
                 plug: capturing([%{"watchlist_id" => "wl-new"}], me),
                 retry_attempts: 0
               )

      assert watchlist.id == "wl-new"
      assert watchlist.symbols == []
      assert_receive {:request, "POST", "/market-data/watchlists/create", _query, raw}
      assert Jason.decode!(raw) == %{"name" => "Empty"}
      refute_receive {:request, "POST", "/market-data/watchlists/instruments/add", _q, _r}
    end

    test "members are added by a second request" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.method, conn.request_path, conn.query_string, raw})

        body =
          if conn.request_path =~ "create" do
            [%{"watchlist_id" => "wl-new"}]
          else
            [%{"success" => true}]
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, watchlist} =
               Rest.create_watchlist("Tech", ["AAPL", "GOOG"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert watchlist.symbols == ["AAPL", "GOOG"]
      assert_receive {:request, "POST", "/market-data/watchlists/create", _q1, _r1}
      assert_receive {:request, "POST", "/market-data/watchlists/instruments/add", _q2, raw}

      assert Jason.decode!(raw)["instruments"] == [
               %{"symbol" => "AAPL", "category" => "US_STOCK"},
               %{"symbol" => "GOOG", "category" => "US_STOCK"}
             ]
    end

    test "a failed add reports the watchlist that now exists and is empty" do
      # A caller that saw {:ok, watchlist} would believe the membership took.
      me = self()

      plug = fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)

        if conn.request_path =~ "create" do
          send(me, :created)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([%{"watchlist_id" => "wl-orphan"}]))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([%{"success" => false}]))
        end
      end

      assert {:error, {:watchlist_created_without_members, "wl-orphan", _reason}} =
               Rest.create_watchlist("Tech", ["AAPL"], @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive :created
    end
  end

  describe "updating and deleting" do
    test "an update changes properties and refuses membership" do
      # The venue's update endpoint does not touch membership; silently skipping the option
      # would leave a caller believing the list changed.
      assert {:error, :membership_not_updatable_here} =
               Rest.update_watchlist("wl-1", @credentials, symbols: ["AAPL"])
    end

    test "an update sends only what was given, and reports membership as unread" do
      me = self()

      assert {:ok, watchlist} =
               Rest.update_watchlist("wl-1", @credentials,
                 name: "Renamed",
                 plug: capturing(ok_body(), me),
                 retry_attempts: 0
               )

      assert watchlist.name == "Renamed"
      assert watchlist.symbols == nil
      assert_receive {:request, "POST", "/market-data/watchlists/update", _query, raw}
      assert Jason.decode!(raw) == %{"watchlist_id" => "wl-1", "name" => "Renamed"}
    end

    test "a delete answers :ok rather than the venue's boolean" do
      assert {:ok, :ok} =
               Rest.delete_watchlist("wl-1", @credentials, plug: ok(), retry_attempts: 0)
    end

    test "a delete the venue declined is a refusal, not a successful call" do
      # `{"success": false}` is a 200 that deleted nothing.
      assert {:refused, :watchlist_write_rejected} =
               Rest.delete_watchlist("wl-1", @credentials,
                 plug: responding([%{"success" => false}]),
                 retry_attempts: 0
               )
    end
  end

  describe "membership writes" do
    test "adding sends symbol and category per instrument" do
      me = self()

      assert {:ok, _result} =
               Rest.add_watchlist_instruments("wl-1", ["AAPL"], @credentials,
                 plug: capturing(ok_body(), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/watchlists/instruments/add"

      assert Jason.decode!(raw) == %{
               "watchlist_id" => "wl-1",
               "instruments" => [%{"symbol" => "AAPL", "category" => "US_STOCK"}]
             }
    end

    test "removing uses its own path, and is by symbol rather than instrument id" do
      me = self()

      assert {:ok, _result} =
               Rest.remove_watchlist_instruments("wl-1", ["AAPL"], @credentials,
                 plug: capturing(ok_body(), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/watchlists/instruments/remove"

      assert Jason.decode!(raw)["instruments"] == [
               %{"symbol" => "AAPL", "category" => "US_STOCK"}
             ]
    end

    test "an empty symbol list is refused before a request is made" do
      assert {:error, :symbols_required} =
               Rest.add_watchlist_instruments("wl-1", [], @credentials, [])

      assert {:error, :symbols_required} =
               Rest.remove_watchlist_instruments("wl-1", [], @credentials, [])
    end

    test "a rejected membership write is a refusal on both paths" do
      opts = [plug: responding([%{"success" => false}]), retry_attempts: 0]

      assert {:refused, :watchlist_write_rejected} =
               Rest.add_watchlist_instruments("wl-1", ["AAPL"], @credentials, opts)

      assert {:refused, :watchlist_write_rejected} =
               Rest.remove_watchlist_instruments("wl-1", ["AAPL"], @credentials, opts)
    end

    test "a reorder needs positions, and sends them per symbol" do
      # A call without positions would send the venue a list of symbols with no change in it.
      assert {:error, :sorts_required} =
               Rest.sort_watchlist_instruments("wl-1", @credentials, [])

      me = self()

      assert {:ok, _result} =
               Rest.sort_watchlist_instruments("wl-1", @credentials,
                 sorts: %{"AAPL" => 1},
                 plug: capturing(ok_body(), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert path == "/market-data/watchlists/instruments/update"

      assert Jason.decode!(raw)["instruments"] == [
               %{"symbol" => "AAPL", "category" => "US_STOCK", "sort" => 1}
             ]
    end
  end

  describe "the fake and the facade" do
    test "the fake keeps both absences" do
      assert {:ok, [watchlist]} = Fake.list_watchlists()
      assert watchlist.symbols == nil

      assert {:ok, read} = Fake.get_watchlist("wl-1")
      assert read.name == nil
      assert read.symbols == ["AAPL", "GOOG"]
    end

    test "the fake refuses a membership update" do
      assert {:error, :membership_not_updatable_here} =
               Fake.update_watchlist("wl-1", symbols: ["AAPL"])

      assert {:ok, %{name: "Renamed"}} = Fake.update_watchlist("wl-1", name: "Renamed")
      assert {:ok, :ok} = Fake.delete_watchlist("wl-1")
    end

    test "the facade delegates all eight" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, [_watchlist]} =
               DpExchange.Webull.list_watchlists(base ++ [plug: responding([%{}])])

      assert {:ok, _read} =
               DpExchange.Webull.get_watchlist("wl-1", base ++ [plug: responding([%{}])])

      assert {:ok, _created} =
               DpExchange.Webull.create_watchlist(
                 "Tech",
                 [],
                 base ++ [plug: responding([%{"watchlist_id" => "wl-new"}])]
               )

      assert {:ok, _updated} =
               DpExchange.Webull.update_watchlist("wl-1", base ++ [name: "X", plug: ok()])

      assert {:ok, :ok} = DpExchange.Webull.delete_watchlist("wl-1", base ++ [plug: ok()])

      assert {:ok, _added} =
               DpExchange.Webull.add_watchlist_instruments("wl-1", ["AAPL"], base ++ [plug: ok()])

      assert {:ok, _removed} =
               DpExchange.Webull.remove_watchlist_instruments(
                 "wl-1",
                 ["AAPL"],
                 base ++ [plug: ok()]
               )

      assert {:ok, _sorted} =
               DpExchange.Webull.sort_watchlist_instruments(
                 "wl-1",
                 base ++ [sorts: %{"AAPL" => 1}, plug: ok()]
               )
    end
  end

  defp ok_body, do: [%{"success" => true}]
end
