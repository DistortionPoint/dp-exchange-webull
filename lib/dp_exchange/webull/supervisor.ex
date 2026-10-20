defmodule DpExchange.Webull.Supervisor do
  @moduledoc """
  This venue's process tree — internal.

  ## The limiter is configured from what `capabilities/0` declares

  The declaration is not decoration beside the mechanism; it **is** the mechanism's
  configuration, so the two cannot drift.

  Webull is the venue whose REST budget is the binding constraint in the family — the
  prior adapter measured 118 ms per call across 342 symbols — so the ceiling here matters
  more than on venues with room to spare.

  ## Production and UAT run side by side, with separate everything

  A consumer trading live while testing against UAT is running two of this venue at once.
  Every default name derives from the environment so the two neither collide nor share a
  rate-limit bucket — the second of which is the dangerous one: UAT traffic metering
  against the production budget would surface as a throttle on a real order, with nothing
  pointing back at the cause.

  A `:name` of your own is enough to run two of the same environment under different
  credentials: the feed, the limiter and the ledger are named `<name>.Feed`,
  `<name>.RateLimiter` and `<name>.Ledger`, and a facade call given the same `name:` addresses
  them. Explicit `:feed` / `:limiter` / `:ledger` still win.

  ## The ledger: a restarted feed picks up where it was

  `Feed` keeps what it was asked to do (wanted symbols, subscribers, replay options) in its own
  state, which a crash empties. `DpExchange.Webull.Ledger` is started before it, outlives it, and
  is written on every accepted change; a restarted feed reads it back (see `Feed`).
  """

  use Supervisor

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Webull.{Environment, Feed, Ledger}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    # Wrapped here as well as in `DpExchange.Webull.child_spec/1`: a caller that reaches
    # `start_link/1` directly (the documented route for a delivery target other than the
    # supervisor) used to leave the raw map in the init argument and in the Feed child
    # spec's start arguments, both of which OTP prints in a crash or supervisor report.
    # Idempotent - `Credentials.wrap/1` passes a wrapped struct through.
    opts = DpExchange.Webull.Credentials.wrap_opt(opts)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(opts))
  end

  @impl true
  def init(opts) do
    # `Feed` never guesses a limiter name for itself — it only ever forwards whatever
    # `:limiter` its own opts carry (into `resubscribe_opts`, and from there into every
    # blind resubscribe and reconnect replay). Starting it with the bare `opts` this tree
    # was given, the way `feed_name`/`name` above are threaded, silently left `:limiter`
    # absent whenever a consumer followed the documented `children = [{DpExchange.Webull,
    # []}]` form: `Core.HttpClient` then resolved the limiter by its bare module name
    # (`DpExchange.Core.DefaultRateLimiter`), which nothing in this tree starts under that
    # name — only under `limiter_name(opts)`, registered just above — so every HTTP call
    # `Subscription` makes on `Feed`'s behalf failed closed with "Rate limiter
    # unavailable", every time, for any consumer who did not separately pass `:limiter`
    # explicitly on every single call. `with_limiter/1` on the facade already defaults it
    # for every REST-backed function; this is the same default, made explicit here so
    # `Feed`'s own `resubscribe_opts` — built once at `init/1` and replayed on every
    # reconnect and blind resubscribe thereafter — actually names the limiter this
    # Supervisor just started, not the one nobody starts.
    children = [
      # First, so it exists when the feed starts and outlives it: it holds what the feed was
      # asked to do, for a restarted feed to pick up. See `DpExchange.Webull.Ledger`.
      {Ledger, name: ledger_name(opts)},
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits(opts)},
      {Feed,
       opts
       |> Keyword.put_new(:limiter, limiter_name(opts))
       |> Keyword.put(:ledger, ledger_name(opts))
       |> Keyword.put(:name, feed_name(opts))}
    ]

    # `:one_for_one` — the feed losing its socket is not a reason to reset the limiter,
    # and resetting it would hand back budget the venue has already been spent. Nor is the
    # feed crashing a reason to reset the ledger: surviving that is what it is for.
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "This tree's registered name, environment-derived."
  @spec supervisor_name(keyword()) :: atom()
  def supervisor_name(opts) do
    Keyword.get_lazy(opts, :name, fn ->
      env_default(opts, __MODULE__, DpExchange.Webull.UatSupervisor)
    end)
  end

  @doc """
  The limiter this venue meters against: `:limiter` if given, else `<name>.RateLimiter` for a
  tree started with its own `:name`, else the environment's default.
  """
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts) do
    Keyword.get_lazy(opts, :limiter, fn ->
      child_name(
        opts,
        "RateLimiter",
        DpExchange.Webull.RateLimiter,
        DpExchange.Webull.UatRateLimiter
      )
    end)
  end

  @doc "This venue's feed process, named the way `limiter_name/1` names the limiter."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts) do
    Keyword.get_lazy(opts, :feed, fn ->
      child_name(opts, "Feed", Feed, DpExchange.Webull.UatFeed)
    end)
  end

  @doc "The process holding what the feed was asked to do, named the way `limiter_name/1` is."
  @spec ledger_name(keyword()) :: atom()
  def ledger_name(opts) do
    Keyword.get_lazy(opts, :ledger, fn ->
      child_name(opts, "Ledger", Ledger, DpExchange.Webull.UatLedger)
    end)
  end

  # **Two trees in one VM need distinct names for every process, and `name:` alone must be
  # enough to get them.** The defaults derived from the environment only, so a second tree given
  # just `name: :account_b` collided on the feed and the limiter. A tree whose `:name` is not
  # its environment's default now names its children `<name>.Feed`, `<name>.RateLimiter` and
  # `<name>.Ledger`. An explicit `:feed`, `:limiter` or `:ledger` still wins, and a tree with no
  # `:name` keeps today's names exactly. Facade calls resolve the same names from `name:` in
  # their options.
  defp child_name(opts, suffix, production, uat) do
    case custom_name(opts) do
      nil -> env_default(opts, production, uat)
      name -> Module.concat(name, suffix)
    end
  end

  defp custom_name(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) ->
        if name in [__MODULE__, DpExchange.Webull.UatSupervisor], do: nil, else: name

      _no_custom_name ->
        nil
    end
  end

  defp env_default(opts, production, uat) do
    case Environment.resolve(opts) do
      :production -> production
      :uat -> uat
    end
  end

  # **Two limits, so two buckets.** Every endpoint page states both: "1 request per second
  # per App Key" and "Market Data Global Limit: 600 requests per minute"
  # (docs/reference/webull/rest-rate-limits.md). This used to be one shared bucket at
  # 60/60s with a burst of 60, read as "1 per second in other units". It is not the same
  # thing: a burst of 60 let a backfill send a minute's budget to one endpoint at once, and
  # the venue refused all but the first in each second. A consumer's log on 2026-10-02 showed
  # 45 `429`s with `retry_after=5s` on crypto bars. That one bucket also held every OTHER
  # endpoint to the same 60 a minute, a tenth of the global budget.
  #
  # So each endpoint is metered alone at the stated rate with a burst of 1 (strictly 1 per
  # second), and all of them together against the global 600/60s.
  @market_data_global %{limit: 600, per_ms: 60_000}
  @endpoint_burst 1
  # Ours, not the venue's. It publishes no burst depth for the global cap, so this allows
  # one second's worth at its stated rate.
  @global_burst 10

  @doc """
  The limits this venue's `DefaultRateLimiter` is started with, for the environment `opts`
  resolves to.

  Public for the same reason `limiter_name/1` and `feed_name/1` are: it is a derivation a
  reader has to be able to check, and the figure it produces gates every REST call this
  package makes. Not part of the facade — `DpExchange.Webull` is the boundary.
  """
  @spec limits(keyword()) :: %{
          atom() => %{limit: pos_integer(), per_ms: pos_integer(), burst: pos_integer()}
        }
  def limits(opts) do
    caps = DpExchange.Webull.capabilities()
    environment = Environment.resolve(opts)
    endpoint = environment_ceiling(caps.public_ceiling, environment)
    global = environment_ceiling(@market_data_global, environment)

    # `:webull` is the bucket every request clears; `:default` is what each endpoint's own
    # bucket (`"webull <path>"`, from `rate_limit_per_endpoint: true`) takes. See
    # `@market_data_global` and `@endpoint_burst`.
    %{
      webull: %{limit: global.limit, per_ms: global.per_ms, burst: @global_burst},
      default: %{limit: endpoint.limit, per_ms: endpoint.per_ms, burst: @endpoint_burst}
    }
  end

  # `capabilities/0` declares the PRODUCTION ceiling and can declare nothing else: it takes
  # no arguments, so it cannot state a figure that differs per environment, and production
  # is the figure a consumer is entitled to read as this venue's contract.
  #
  # The venue's per-endpoint rate-limit table gives sandbox exactly half of the
  # production limit this package meters — `30/60s` against `60/60s`. (Its Non-Display
  # table, as read 2026-10-18, gives production `300/60s` against the same `30/60s`
  # sandbox, so "half" is the Display relationship; see `rest-rate-limits.md`.) UAT is
  # therefore metered at half here rather than silently inheriting a budget
  # twice what that environment permits. For the per-endpoint bucket the halving is the
  # venue's own relationship between its two columns. The GLOBAL 600/60s bucket is halved
  # too, but that is this package's assumption: the venue's table gives no sandbox figure for
  # the global cap, so 300/60s is a conservative guess, not a documented number.
  #
  # This matters for the reason the moduledoc above already gives about buckets: UAT and
  # production are separately named limiters precisely so one cannot spend the other's
  # budget. Giving them the same LIMITS would have left that separation cosmetic in the
  # direction that bites — UAT traffic pacing itself against a production allowance the
  # sandbox will refuse, surfacing as a 429 on a test run with nothing pointing at why.
  defp environment_ceiling(ceiling, :production), do: ceiling

  defp environment_ceiling(%{limit: limit} = ceiling, :uat),
    do: %{ceiling | limit: max(div(limit, 2), 1)}
end
