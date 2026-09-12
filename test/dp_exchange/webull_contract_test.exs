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
    package_root: "lib/dp_exchange",
    # The options this venue's own endpoints require before its fake will answer at all.
    #
    # Without these, every fake-driven assertion that calls an account-scoped endpoint was
    # refused for the MISSING ACCOUNT before it reached the behaviour under test, and the
    # suite took that refusal as a legitimate answer and skipped. Assertion 24 is how it
    # surfaced: niling this package's fake balance currency on purpose left the suite green,
    # while the two venues that need no account went red. Assertion 17 had the same shape —
    # it strips credentials and expects a failure, and got one for the account rather than
    # the credential.
    #
    # The key is this venue's, not Core's. A table of `:account_id` / `:account_number` /
    # `:account_hash` inside the contract would be exactly the venue-specific knowledge the
    # contract exists to keep out of Core.
    endpoint_opts: %{
      {:get_balances, 2} => [account_id: "contract-account"],
      {:get_accounts, 2} => [account_id: "contract-account"],
      {:get_orders, 2} => [account_id: "contract-account"],
      {:place_order, 3} => [account_id: "contract-account"],
      {:cancel_order, 3} => [account_id: "contract-account"],
      {:get_order, 3} => [account_id: "contract-account"]
    },
    # This venue serves an order book for US stocks and ETFs and refuses one for a crypto
    # pair — the venue publishes no crypto depth endpoint, and `Fake.get_order_book/2`
    # refuses it "the same way the real package does rather than inventing a book". Every
    # entry in `sample_pairs:` above is crypto, so Core's assertion 23 could only ever see
    # that refusal, and its own skip-on-refusal clause then passed without checking
    # anything.
    #
    # Naming a symbol this endpoint actually serves makes the assertion RUN. The refusal is
    # still correct and still covered — `order_book_test.exs` asserts it directly.
    endpoint_symbols: %{{:get_order_book, 2} => "AAPL"}
end
