defmodule DpExchange.Webull.RateCeilingTest do
  @moduledoc """
  The REST ceiling, and the environment split applied to it.

  This number has been wrong twice — `10` uncited, then `5` from a vendor FAQ page that
  the vendor's own per-endpoint table contradicts by a factor of five. Both times it was
  too permissive, and this venue answers an exceeded limit with `429` and then, in its own
  words, "temporary IP-level blocking". So the figure is pinned here rather than left to
  whatever `capabilities/0` happens to say: a test that fails when someone edits the
  declaration is the point, not an inconvenience.

  See `docs/reference/webull/rest-rate-limits.md` for the vendor sources and the full
  history of both corrections.
  """
  use ExUnit.Case, async: true

  alias DpExchange.Webull.Supervisor, as: WebullSupervisor

  describe "the declared ceiling" do
    test "is the venue's documented 60 requests per 60 seconds, in the venue's own units" do
      caps = DpExchange.Webull.capabilities()

      assert caps.public_ceiling == %{limit: 60, per_ms: 60_000}
      assert caps.authenticated_ceiling == %{limit: 60, per_ms: 60_000}
    end

    test "makes no public/authenticated split, because every endpoint here is signed" do
      caps = DpExchange.Webull.capabilities()

      assert caps.credential_benefit == :required
      assert caps.public_ceiling == caps.authenticated_ceiling
    end

    # The first test above pins `per_ms: 60_000` as well: `60/60_000` and `1/1_000` are the
    # same average rate and NOT the same limiter. The venue permits a window, so reducing it
    # to a per-second figure would silently throw away the burst it actually allows.
  end

  describe "limits/1 derives the limiter's configuration from that declaration" do
    test "production: each endpoint at the declared 1/s with a burst of 1, all of them at 600/60s" do
      # Two limits, two buckets — see `Supervisor`'s "Two limits, so two buckets". A burst of
      # 60 on one shared bucket drew 45 `429`s from crypto bars in a consumer's log.
      assert %{webull: global, default: endpoint} =
               WebullSupervisor.limits(environment: :production)

      assert endpoint == %{limit: 60, per_ms: 60_000, burst: 1}
      assert global == %{limit: 600, per_ms: 60_000, burst: 10}
    end

    test "sandbox is half of both, which is the venue's own relationship between its columns" do
      assert %{webull: global, default: endpoint} = WebullSupervisor.limits(environment: :uat)

      assert endpoint == %{limit: 30, per_ms: 60_000, burst: 1}
      assert global == %{limit: 300, per_ms: 60_000, burst: 10}
    end

    test "the two environments do not share a figure" do
      # The Supervisor already gives production and UAT separately *named* limiters so one
      # cannot spend the other's budget. Handing both the same LIMITS would leave that
      # separation cosmetic in the direction that bites: UAT pacing itself against an
      # allowance the sandbox refuses.
      production = WebullSupervisor.limits(environment: :production)
      uat = WebullSupervisor.limits(environment: :uat)

      refute production.webull.limit == uat.webull.limit
      refute production.default.limit == uat.default.limit
    end

    test "defaults to production when no environment is given" do
      assert WebullSupervisor.limits([]) == WebullSupervisor.limits(environment: :production)
    end

    test "an endpoint's burst is 1 in both environments, never its limit" do
      assert %{default: %{burst: 1}} = WebullSupervisor.limits(environment: :uat)
      assert %{default: %{burst: 1}} = WebullSupervisor.limits(environment: :production)
    end

    test "against the real limiter: one endpoint is held to 1/s, another is not held by it" do
      name = :"webull_limits_#{System.unique_integer([:positive])}"

      start_supervised!(
        {DpExchange.Core.DefaultRateLimiter,
         name: name, limits: WebullSupervisor.limits(environment: :production)}
      )

      bars = "webull /market-data/crypto/bars/list"
      snapshot = "webull /market-data/crypto/snapshots/list"

      assert :ok = DpExchange.Core.DefaultRateLimiter.check(bars, 1, limiter: name)
      :ok = DpExchange.Core.DefaultRateLimiter.record(bars, 1, limiter: name)

      assert {:rate_limited, wait_ms} =
               DpExchange.Core.DefaultRateLimiter.check(bars, 1, limiter: name)

      # Bounded by the refill interval of one request per second. The old `> 900` lower
      # bound failed whenever the scheduler stalled this process for 100ms between `record`
      # and `check`; the `rate_limited` match above is what proves the burst is 1.
      assert wait_ms in 1..1_000
      assert :ok = DpExchange.Core.DefaultRateLimiter.check(snapshot, 1, limiter: name)
    end
  end
end
