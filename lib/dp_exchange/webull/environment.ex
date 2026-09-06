defmodule DpExchange.Webull.Environment do
  @moduledoc """
  Which Webull this package is talking to — production, or the UAT environment.

  ## This venue's demo story is only half a story, and that half matters

  Gemini's demo environment is a complete parallel exchange: REST and streaming both. This
  one is not.

  | | Production | UAT |
  |---|---|---|
  | REST | `api.webull.com` | `us-openapi-alb.uat.webullbroker.com` |
  | Streaming | `wss://data-api.webull.com:8883/mqtt` | **none** |

  The prior adapter records the measurement that establishes it:
  `mqtt-uat.webullbroker.com` → **NXDOMAIN**. There is no UAT broker to connect to, and no
  amount of configuration produces one.

  So `environment: :uat` gives a consumer authenticated REST against test data and **no
  live stream at all**. That is a genuinely useful thing — order placement and account
  calls can be exercised without money — and it is also a trap if a package pretends
  otherwise. `subscribe/2` in UAT does not silently fall back to production, because a
  consumer testing against UAT who received *production* prices would be reading real
  market data while believing it was fake. It refuses.

  **`streaming?/1` exists so a caller can ask before it commits**, rather than discovering
  the gap from a subscription that never delivers.

  ## Resolution order

  1. an explicit `:environment` in the call's options — wins always
  2. `DpExchange.Core.Config`, which resolves per **process**, so one async test or one
     strategy runner can sit in UAT while its neighbours do not
  3. `:production`

  Production is the default and an unrecognised value **raises**. A typo must not quietly
  resolve to production: the failure is asymmetric, since meaning UAT and getting
  production sends a real order to a real broker.
  """

  alias DpExchange.Core.Config

  @type t :: :production | :uat

  @rest %{
    production: "https://api.webull.com",
    uat: "https://us-openapi-alb.uat.webullbroker.com"
  }

  @hosts %{production: "api.webull.com", uat: "us-openapi-alb.uat.webullbroker.com"}

  @streaming %{production: "wss://data-api.webull.com:8883/mqtt", uat: nil}

  @doc "The environment in force for these options."
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    opts
    |> Keyword.get_lazy(:environment, fn ->
      Config.get(:dp_exchange_webull, :environment, :production)
    end)
    |> validate!()
  end

  @doc "REST base URL, with scheme."
  @spec rest_url(t()) :: String.t()
  def rest_url(environment), do: Map.fetch!(@rest, environment)

  @doc """
  REST hostname without a scheme.

  Separate from `rest_url/1` because **the host participates in the signature** — Webull
  signs it so a signature cannot be replayed against another environment. A caller needs
  both, and they must agree.
  """
  @spec host(t()) :: String.t()
  def host(environment), do: Map.fetch!(@hosts, environment)

  @doc """
  The MQTT-over-WebSocket URL, or `nil` where the venue offers none.

  `nil` is the honest answer for UAT and is not a configuration gap to fill in.
  """
  @spec streaming_url(t()) :: String.t() | nil
  def streaming_url(environment), do: Map.fetch!(@streaming, environment)

  @doc """
  Whether this environment has a live stream at all.

  Asked before subscribing, so a consumer learns the answer from a question rather than
  from a subscription that never delivers.
  """
  @spec streaming?(t()) :: boolean()
  def streaming?(environment), do: not is_nil(streaming_url(environment))

  @doc "Whether this environment moves real money."
  @spec live?(t()) :: boolean()
  def live?(:production), do: true
  def live?(:uat), do: false

  @doc "Every environment this package knows."
  @spec known() :: [t()]
  def known, do: [:production, :uat]

  # `known/0` is the single source of truth for what this module recognises — `validate!/1`
  # used to carry its own literal `[:production, :uat]` guard, a second copy of the same
  # list that `known/0` could drift from silently if either one were updated alone. Routed
  # through the function instead, so there is exactly one place this package's set of known
  # environments is written down. Same fix, same reasoning, as `DpExchange.Gemini.Environment`.
  defp validate!(environment) do
    if environment in known() do
      environment
    else
      raise ArgumentError,
            "unknown Webull environment #{inspect(environment)} — expected one of " <>
              "#{inspect(known())}. Refusing rather than defaulting: a typo that silently " <>
              "resolved to :production would send a real order to a real broker."
    end
  end
end
