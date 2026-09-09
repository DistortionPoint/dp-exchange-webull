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

    test "is stated as a 60s window rather than reduced to a per-second rate" do
      # `60/60_000` and `1/1_000` are the same average rate and NOT the same limiter: the
      # venue permits a window, so reducing it to a per-second figure would silently throw
      # away the burst it actually allows. Transcribe the vendor's units.
      caps = DpExchange.Webull.capabilities()

      assert caps.public_ceiling.per_ms == 60_000
    end
  end

  describe "limits/1 derives the limiter's configuration from that declaration" do
    test "production is the declared ceiling, unmodified" do
      assert %{webull: webull, default: default} =
               WebullSupervisor.limits(environment: :production)

      assert webull == %{limit: 60, per_ms: 60_000, burst: 60}
      assert default == webull
    end

    test "sandbox is half, which is the venue's own relationship between its two columns" do
      assert %{webull: webull} = WebullSupervisor.limits(environment: :uat)

      assert webull == %{limit: 30, per_ms: 60_000, burst: 30}
    end

    test "the two environments do not share a figure" do
      # The Supervisor already gives production and UAT separately *named* limiters so one
      # cannot spend the other's budget. Handing both the same LIMITS would leave that
      # separation cosmetic in the direction that bites: UAT pacing itself against an
      # allowance the sandbox refuses.
      production = WebullSupervisor.limits(environment: :production)
      uat = WebullSupervisor.limits(environment: :uat)

      refute production.webull.limit == uat.webull.limit
    end

    test "defaults to production when no environment is given" do
      assert WebullSupervisor.limits([]) == WebullSupervisor.limits(environment: :production)
    end

    test "burst tracks the environment's own limit, never production's" do
      # `to_limit/1` defaults burst to the limit. The halving has to happen BEFORE that
      # default is applied, or sandbox would carry a production-sized burst — the exact
      # shape of the bug this test exists for, one layer down.
      assert %{webull: %{burst: 30, limit: 30}} = WebullSupervisor.limits(environment: :uat)
    end
  end
end
