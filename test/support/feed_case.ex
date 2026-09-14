defmodule DpExchange.Webull.FeedCase do
  @moduledoc """
  The shared fixtures behind the feed test files, and why there is more than one file.

  These tests wait on real timers — a tick boundary, a reconcile deadline expiring, a
  successor surviving its predecessor's deadline, a call outlasting `GenServer.call/2`'s
  five-second default. None of that waiting can be trimmed without deleting the thing being
  proved, and ExUnit parallelises across FILES but serialises within one, so concentrating
  them made every wait run end to end rather than alongside the others.

  The margins here are deliberately wide. Shrinking them to buy speed is how a suite becomes
  flaky under load, which this family has already paid for several times; splitting files is
  how the same waiting gets cheaper without touching a single margin.

  This module exists so the split files cannot drift apart: one `PermissiveLimiter`, one
  named limiter per test, one `start_feed/1`, one set of fixtures. Three of these files each
  carried their own copy before. A helper exactly one file uses stays in that file.
  """

  use ExUnit.CaseTemplate

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Webull.Feed

  using do
    quote do
      import DpExchange.Webull.FeedCase

      @moduletag :capture_log
    end
  end

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

    # The feed's HTTP subscribe runs inside the GenServer, so a real limiter is started
    # and named rather than relying on a process-scoped override the feed cannot see.
    limiter = :"limiter_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  @credentials %{app_key: "k", app_secret: "s"}

  @doc "The credential map every feed here is started with."
  @spec credentials() :: map()
  def credentials, do: @credentials

  @doc """
  The HTTP half of subscribing, answered without a network.

  Every subscribe on this venue is a REST call, so a feed test that did not stub one would
  reach the venue.
  """
  @spec subscribe_opts(atom(), keyword()) :: keyword()
  def subscribe_opts(limiter, extra \\ []) do
    plug = fn conn -> Req.Test.json(conn, %{"code" => "200"}) end

    Keyword.merge(
      [credentials: @credentials, plug: plug, retry_attempts: 0, limiter: limiter],
      extra
    )
  end

  @doc """
  A pre-connected shard 0, standing in for one that already opened and saw its CONNACK.

  What every test except the ones about the connecting window itself wants to assume.
  `session_id` is overridable because some tests assert on it.
  """
  @spec connected_shard(String.t() | nil) :: map()
  def connected_shard(session_id \\ nil) do
    %{
      session_id: session_id || "session-#{System.unique_integer([:positive])}",
      socket: self(),
      connected?: true,
      symbols: [],
      reply_to: nil
    }
  end

  @doc "An unnamed feed with one pre-connected shard, unless `opts` says otherwise."
  @spec start_feed(keyword()) :: pid()
  def start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"
    defaults = [name: name, shards: %{0 => connected_shard()}]
    {:ok, pid} = Feed.start_link(Keyword.merge(defaults, opts))
    pid
  end

  @doc "A minimal quote for `symbol`."
  @spec quote_for(String.t()) :: Quote.t()
  def quote_for(symbol) do
    %Quote{
      symbol: symbol,
      price: Decimal.new("1"),
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :webull
    }
  end

  @doc "A minimal top-of-book for `symbol`."
  @spec top_of_book_for(String.t()) :: TopOfBook.t()
  def top_of_book_for(symbol) do
    %TopOfBook{
      symbol: symbol,
      bid: Decimal.new("1"),
      ask: Decimal.new("2"),
      bid_size: nil,
      ask_size: nil,
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :webull
    }
  end

  @doc "The notice a shard's socket sends when its session links up."
  @spec link_up(String.t()) :: Notice.t()
  def link_up(session_id), do: Notice.new(:link_up, :webull, details: %{session_id: session_id})

  @doc "The notice a shard's socket sends when its session drops."
  @spec link_down(String.t()) :: Notice.t()
  def link_down(session_id),
    do: Notice.new(:link_down, :webull, details: %{session_id: session_id})
end
