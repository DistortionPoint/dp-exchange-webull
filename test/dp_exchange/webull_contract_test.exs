defmodule DpExchange.WebullContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.

  ## `package_root: "lib/dp_exchange"`

  Narrower than the suite's own `"lib"` default, and deliberately so: `lib/vendor/`
  (currently just `DpExchange.Webull.Vendor.WebSockex` — see its own moduledoc for why
  it exists, dp-exchange-core issue #27) is third-party code this package carries, not
  code written to this family's own conventions. Assertions 16 (internal wiring), the
  link-safety check and 19 (credential redaction) all scan whatever `package_root`
  names; `lib/vendor/` sitting outside `lib/dp_exchange` is what keeps them scoped to
  code this package actually authored. Every module this package itself owns still
  lives under `lib/dp_exchange/`, so this changes what gets excluded, not what gets
  included — confirmed by `find lib -maxdepth 2 -type d` showing no other subtree.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Webull,
    fake: DpExchange.Webull.Fake,
    symbol_format: DpExchange.Webull.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD SOL-USD),
    credentials: %{app_key: "test-app-key", app_secret: "test-app-secret"},
    package_root: "lib/dp_exchange"
end
