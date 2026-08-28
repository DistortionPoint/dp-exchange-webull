defmodule DpExchange.Webull.SymbolFormat do
  @moduledoc """
  Webull's symbol mapping.

  Native form is **concatenated, no separator**: `BTCUSD`. Canonical is `BASE-QUOTE`. So
  both directions do real work, and the same overlapping-quote hazard applies as on any
  `sep: ""` venue — the quote list is consulted in order, and a shorter quote that is also
  the tail of a longer one wins if checked first.

  `USDT` and `USDC` therefore precede `USD`. Without that, `BTCUSDT` splits as `BTCUS`/`DT`
  or `BTCUSD`/`T` depending on the list, and neither is an asset.

  ## Why both directions run through `CanonicalPair`

  So they cannot drift. The adapter this came from records why that matters: an audit
  found `build_order_body` sending the **canonical** symbol to the venue un-converted, so
  reads worked and writes silently did not. Running every path — read and write — through
  one mapping is the fix, and it only works if there is exactly one mapping.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.CanonicalPair

  # Longest-first. `USDT` and `USDC` before `USD` is the ordering the venue's own
  # stablecoin pairs depend on.
  @mapping %{sep: "", quotes: ~w(USDT USDC USD BTC ETH)}

  @doc "The mapping, exposed so the conformance suite can drive `CanonicalPair` with it."
  @spec mapping() :: CanonicalPair.mapping()
  def mapping, do: @mapping

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: @mapping.quotes

  @impl true
  @spec to_canonical_symbol(String.t()) :: String.t()
  def to_canonical_symbol(native) when is_binary(native),
    do: CanonicalPair.to_canonical(@mapping, native)

  @impl true
  @spec to_exchange_symbol(String.t()) :: String.t()
  def to_exchange_symbol(canonical) when is_binary(canonical),
    do: CanonicalPair.to_exchange(@mapping, canonical)
end
