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

  Explicit `:name` / `:feed` / `:limiter` still win, for running two of the same
  environment under different credentials.
  """

  use Supervisor

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Webull.{Environment, Feed}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
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
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits()},
      {Feed,
       opts
       |> Keyword.put_new(:limiter, limiter_name(opts))
       |> Keyword.put(:name, feed_name(opts))}
    ]

    # `:one_for_one` — the feed losing its socket is not a reason to reset the limiter,
    # and resetting it would hand back budget the venue has already been spent.
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "This tree's registered name, environment-derived."
  @spec supervisor_name(keyword()) :: atom()
  def supervisor_name(opts) do
    Keyword.get_lazy(opts, :name, fn ->
      case Environment.resolve(opts) do
        :production -> __MODULE__
        :uat -> DpExchange.Webull.UatSupervisor
      end
    end)
  end

  @doc "The limiter this venue meters against."
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts) do
    Keyword.get_lazy(opts, :limiter, fn ->
      case Environment.resolve(opts) do
        :production -> DpExchange.Webull.RateLimiter
        :uat -> DpExchange.Webull.UatRateLimiter
      end
    end)
  end

  @doc "This venue's feed process."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts) do
    Keyword.get_lazy(opts, :feed, fn ->
      case Environment.resolve(opts) do
        :production -> Feed
        :uat -> DpExchange.Webull.UatFeed
      end
    end)
  end

  # Straight from the declaration. If a ceiling changes, it changes in one place.
  defp limits do
    caps = DpExchange.Webull.capabilities()

    %{webull: to_limit(caps.public_ceiling), default: to_limit(caps.public_ceiling)}
  end

  # No published burst depth on this venue — unlike Gemini, which states one. Falling back
  # to the per-interval limit is the conventional GCRA choice and is labelled as ours
  # rather than the venue's.
  defp to_limit(%{limit: limit, per_ms: per_ms} = ceiling),
    do: %{limit: limit, per_ms: per_ms, burst: Map.get(ceiling, :burst, limit)}
end
