defmodule DpExchange.WebullContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Webull,
    fake: DpExchange.Webull.Fake,
    symbol_format: DpExchange.Webull.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD SOL-USD),
    credentials: %{app_key: "test-app-key", app_secret: "test-app-secret"}
end
