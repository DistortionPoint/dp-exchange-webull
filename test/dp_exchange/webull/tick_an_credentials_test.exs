defmodule DpExchange.Webull.TickAnCredentialsTest do
  @moduledoc """
  The credentials a `Feed` replays with are never replaced by ones it cannot sign with.

  The venue-specific item of tick AN: a live run once recorded `missing_required_field
  app_key` while a shard was open, and it was never explained. That error is this package's
  own (`Feed.open_socket/2`), not the venue's. It is answered whenever a shard has to be OPENED
  from credentials with no usable App Key, and the replay paths (a reopen after a crash or an
  `INVALID_SESSION`, a staggered background open, the post-CONNACK replay) open from
  `state.resubscribe_opts`.

  `Feed.replayable/2` merged a call's `credentials:` over the stored ones whatever it held.
  `credentials: nil`, `%{}` or a map with a blank secret replaced the working credentials, and
  the call itself was refused at signing (or answered `:ok` where it changed nothing), so the
  emptied credentials were what every later reopen used. A call refused for a different reason
  (a 401 under a rotated key) also left its credentials stored: a refused call changes no state.
  """

  use DpExchange.Webull.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.{Credentials, Feed}

  @unusable [
    nil,
    %{},
    %{app_key: "k2", app_secret: ""},
    %{app_key: " ", app_secret: "s"}
  ]

  defp stored_app_key(feed) do
    case :sys.get_state(feed).resubscribe_opts[:credentials] do
      %Credentials{app_key: app_key} -> app_key
      other -> other
    end
  end

  describe "credentials the package cannot sign with are not stored" do
    test "a no-op call naming nil, an empty map or a blank secret leaves the working ones" do
      feed = start_feed(credentials: credentials())

      for bad <- @unusable do
        assert :ok == Feed.subscribe(feed, [], credentials: bad)
        assert :ok == Feed.update_symbols(feed, [], credentials: bad)
        assert stored_app_key(feed) == "k"
      end
    end

    test "a refused call naming none does not empty them either", %{limiter: limiter} do
      feed = start_feed(credentials: credentials())
      opts = [limiter: limiter, credentials: nil]

      assert {:error, {:missing_credentials, :webull}} = Feed.subscribe(feed, ["BTC-USD"], opts)

      assert Feed.wanted(feed) == []
      assert stored_app_key(feed) == "k"
    end

    test "a reopen after such a call still has the App Key" do
      feed =
        start_feed(
          shards: %{},
          credentials: credentials(),
          url: "ws://127.0.0.1:1/nowhere",
          open_retry_base_ms: 600_000,
          open_retry_max_ms: 600_000
        )

      assert :ok == Feed.subscribe_notices(feed, to: self())
      assert :ok == Feed.subscribe(feed, [], credentials: nil)
      want(feed, ["BTC-USD"])

      send(feed, {:open_shard, 0, ["BTC-USD"], :sys.get_state(feed).resubscribe_opts})

      # The open is attempted, and fails because there is no broker at that address. What it
      # must not fail with is the missing App Key.
      assert_receive {:dp_exchange, :webull, %Notice{kind: :coverage_change} = notice}, 5_000
      assert notice.details.reason == :open_failed
      refute notice.details.message =~ "missing_required_field"
    end
  end

  describe "a refused call changes no state, the credentials it carried included" do
    test "a 401 under a new key leaves the old key stored; an accepted call stores the new one",
         %{limiter: limiter} do
      feed = start_feed(credentials: credentials())
      rotated = %{app_key: "rotated", app_secret: "rotated-secret"}
      deny = fn conn -> Plug.Conn.resp(conn, 401, "") end
      refused = subscribe_opts(limiter, credentials: rotated, plug: deny)
      accepted = subscribe_opts(limiter, credentials: rotated)

      assert {:error, {:refused, 401, _body}} = Feed.subscribe(feed, ["BTC-USD"], refused)
      assert Feed.wanted(feed) == []
      assert stored_app_key(feed) == "k"

      assert :ok == Feed.subscribe(feed, ["BTC-USD"], accepted)
      assert stored_app_key(feed) == "rotated"
    end
  end

  describe "a blank App Key opens no socket" do
    test "an empty or whitespace key is the missing key it is" do
      feed = start_feed(shards: %{})

      for blank <- ["", "   "] do
        opts = [credentials: %{app_key: blank, app_secret: "s"}]

        assert {:error, {:missing_required_field, :app_key}} =
                 Feed.subscribe(feed, ["BTC-USD"], opts)
      end

      assert Feed.wanted(feed) == []
      assert :sys.get_state(feed).shards == %{}
    end
  end
end
