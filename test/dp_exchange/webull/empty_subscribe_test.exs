defmodule DpExchange.Webull.EmptySubscribeTest do
  @moduledoc """
  `subscribe([])` opens nothing (family convention DV9): no shard, no socket, no REST call.

  Verified against `Feed`: an empty list changes no wanted symbol, so the reshard plan is
  empty and the caller is answered `:ok` at once. A feed that opened a connection for no
  symbols would be a socket held open for a consumer who asked for nothing.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.{Fake, Feed}

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
    name = :"empty_subscribe_feed_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link(name: name)
    {:ok, feed: feed}
  end

  test "an empty subscribe answers :ok and opens no shard and makes no request", %{feed: feed} do
    me = self()

    plug = fn conn ->
      send(me, {:request, conn.request_path})
      Req.Test.json(conn, %{"code" => "200"})
    end

    assert :ok =
             Feed.subscribe(feed, [],
               to: me,
               credentials: %{app_key: "k", app_secret: "s"},
               plug: plug,
               retry_attempts: 0
             )

    state = :sys.get_state(feed)
    assert state.shards == %{}
    assert state.wanted == MapSet.new()

    # The call above is synchronous: a request or a shard would already have happened.
    refute_receive {:request, _path}, 50
  end

  test "the fake agrees: an empty subscribe delivers nothing and covers nothing" do
    assert :ok = Fake.subscribe([], [])
    assert Fake.coverage() == %{}
  end
end
