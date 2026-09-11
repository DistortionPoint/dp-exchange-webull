defmodule DpExchangeWebull.MixProject do
  use Mix.Project

  # SEED, not a release. CI increments the last segment of whatever it finds here, so
  # `0.1.0` first publishes as `0.1.1`. Hand-editing this to `0.2.0` is how a breaking
  # change is signalled. The bump script matches the attribute assignment below by its
  # exact literal form — do not reformat it, and do not repeat that form anywhere else
  # in this file, comments included, or the script will rewrite the wrong line.
  @version "0.4.14"
  @source_url "https://github.com/DistortionPoint/dp-exchange-webull"

  def project do
    [
      app: :dp_exchange_webull,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: preferred_cli_env(),
      test_coverage: test_coverage(),

      # Hex.pm
      name: "DpExchangeWebull",
      description:
        "EXPERIMENTAL — Webull venue package for the DpExchange family. Market data, " <>
          "trading and streaming behind the shared DpExchange.Core.Venue facade.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      usage_rules: usage_rules()
    ]
  end

  # No `mod:` — a library does not start itself. A consumer supervises this venue
  # through `child_spec/1` and decides restart strategy, shutdown order and naming. A
  # consumer that has not asked for Webull must not find a socket open.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The contract. Three-part pin: while Core is 0.x a minor bump may break us, and
      # that is the signal it is meant to send.
      #
      # `0.1.68` is the floor because `capabilities/0` declares
      # `no_venue_contact: [{:get_fees, 2}]`, and `Capabilities.new/1` builds the struct
      # with `struct!/2` — a key the struct does not define raises `KeyError` rather than
      # being silently dropped. `no_venue_contact` was added to `Capabilities` in Core
      # 0.1.68; under any lower floor (this pin previously allowed down to 0.1.48) a
      # consumer resolving an old-enough Core gets this package's `capabilities/0`
      # crashing on every call. `~> 0.1.48` compiled and passed here only because CI always
      # resolves the newest allowed version. 0.1.68 also covers `Timeframe.nameable/0`
      # admitting `1y` (needed since 0.1.57 — see `webull_test.exs`'s "1y is declared"
      # test), so it is the binding constraint, not an additional one.
      # `0.2.6` is the floor now, and unlike the history below it is a HARD one: `Feed`
      # calls `Core.Fanout.max_queue_len!/2` in `init/1` and `Core.Fanout.deliver/4` on
      # every payload, and neither existed before 0.2.6. Against a lower Core this package
      # does not merely misbehave, it fails to compile — which is the good outcome, and the
      # reason the floor is stated rather than left to `script/check_dependency_floor.sh` to
      # discover. The older floor history is kept above because its lesson is the one that
      # keeps applying: a floor is only correct once it has been RESOLVED and compiled
      # against, never once it has been reasoned about.
      #
      # `0.3.1` is a MINOR bump, and the signal is deliberate: Core 0.3.0 deleted
      # `Core.DataProvider` and `Core.FeedBehaviour`, two contracts with zero implementers.
      # Nothing in this package referenced either, so there is no code change here — the
      # floor moves because a pin of `~> 0.2.8` would not resolve 0.3.x, which is the pin
      # doing its job rather than a problem to route around. Resolved and compiled against
      # before this line was written, per the lesson recorded below: a floor is only correct
      # once it has been RESOLVED, never once it has been reasoned about.
      #
      {:dp_exchange_core, "~> 0.3.3"},

      # This venue's own transport. Core ships no transport library at any strength —
      # a venue that speaks WebSocket ships what it needs to speak it.
      #
      # `== 0.5.1`, not `~>` — pinned exactly, not floored, since dp-exchange-core issue
      # #27. `DpExchange.Webull.Socket` no longer calls this dependency's own `WebSockex`
      # module directly: it calls `DpExchange.Webull.Vendor.WebSockex`, a private
      # vendored fork of `websockex` 0.5.1's single process-loop file
      # (`lib/vendor/websockex.ex`), carrying a two-line fix. Webull
      # can close this venue's socket with a WebSocket close frame that carries prose
      # instead of an RFC 6455 status code; upstream 0.5.1 (and its unreleased
      # successor, confirmed 2026-09-08) turns that into an uncaught `CaseClauseError`
      # that kills the process before `handle_disconnect/2` ever runs. See the vendored
      # module's own moduledoc for the full incident, exactly what changed (two lines),
      # and why vendoring — not a transport swap, not waiting on upstream — was correct
      # here. This history (the `send_frame/3` arity floor below) is why an exact pin,
      # not a range, is what this dependency gets now.
      #
      # Still required directly: the vendored file calls `WebSockex.Frame`,
      # `WebSockex.Conn`, `WebSockex.Utils`, `WebSockex.Application` and every
      # `WebSockex.*Error` struct from this real, unmodified dependency — none of those
      # carried the bug, and vendoring them too would have tripled the diff for no
      # safety gained.
      #
      # The exact pin matters more here than an ordinary dependency's would: the
      # vendored file calls into `WebSockex.Conn`'s and `WebSockex.Frame`'s functions
      # the same way the original `websockex.ex` did — a private-in-spirit internal API
      # those modules never promised to keep stable across releases the way their own
      # public behaviour is. A `~>` floor invites the exact failure this dependency
      # already caused this family once (below): a version the range permits silently
      # changing a shape this file depends on, with neither SemVer nor this comment's
      # own history catching it. `script/check_dependency_floor.sh` still resolves and
      # compiles this pin — an exact pin removes the *range* failure mode that script
      # exists to catch, not the value of running it.
      #
      # Original floor history, preserved because the lesson still applies: `~> 0.5.1`,
      # not `~> 0.5`, used to be the constraint, because `Socket.disconnect/2` called
      # `WebSockex.send_frame/3` directly and the third argument — the send timeout —
      # only exists from 0.5.1, not 0.5.0. Under `~> 0.4` this package resolved 0.5.1
      # locally and so compiled and passed, while a consumer who resolved 0.4.x got
      # `:undef` at the call. DpCryptoManagement hit exactly that on 2026-09-08. Arity
      # is only checked when the function runs, so it shipped as a compile warning
      # rather than an error, and only on a path nothing exercised.
      #
      # The floor was first corrected to `~> 0.5`, on the belief that the argument
      # landed somewhere in the 0.5 line. `script/check_dependency_floor.sh` (added the
      # same day, to close exactly this blind spot family-wide) resolved that floor for
      # real and found `WebSockex.send_frame/3 is undefined or private` against 0.5.0
      # itself — `send_frame/3` is new in 0.5.1, one patch later than the first fix
      # assumed, and `~> 0.5` still permitted the version that lacks it. Confirmed by
      # reading both resolved sources directly: 0.5.0's `lib/websockex.ex` defines only
      # `send_frame/2`; 0.5.1's defines `send_frame(client, frame, timeout \\ 5_000)`.
      # The lesson this family had already drawn — a "corrected" floor still needs to be
      # resolved to prove it, not just reasoned about — applied to its own correction
      # within the same day.
      #
      # `send_frame/2` works on both and is the WRONG fix: it takes WebSockex's own
      # 5_000ms default, where `@disconnect_timeout_ms` is deliberately 500ms because
      # `disconnect/2` runs inside `Feed.terminate/2`, under a supervisor's shutdown
      # budget. Ten times the wait during shutdown is not a free compatibility win, so
      # the vendored `send_frame/3` (copied verbatim from 0.5.1) is what this package
      # calls now — the honest fix is still to depend on the version whose API this
      # package actually uses, now enforced by an exact pin instead of a range.
      {:websockex, "== 0.5.1"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},

      # Dev/Test
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Exercises the REST pipeline through Req's test seam, so tier-1 tests reach no
      # network. Never ships.
      {:plug, "~> 1.16", only: :test}
    ]
  end

  # `DpExchange.Webull.Vendor.WebSockex` is excluded: a private vendored fork of
  # `websockex` 0.5.1's process-loop file, carrying a two-line fix for dp-exchange-core
  # issue #27 (see its own moduledoc). This package's tier-1 suite exercises the paths
  # this venue actually uses — connect, CONNACK, frame draining, the malformed-close fix
  # itself (`socket_malformed_close_test.exs`), a clean shutdown DISCONNECT — not the
  # SSL transport, named-process registration, `:async` start, fragmented-frame
  # reassembly or `:sys` debug tracing this venue never exercises. Writing tests to hit
  # 90% on code copied verbatim from an already-tested upstream library would mean
  # re-deriving that library's own test suite rather than testing anything about this
  # package. Same reasoning `.credo.exs` and `webull_contract_test.exs`'s narrowed
  # `package_root` already apply to this file for the same reason.
  defp test_coverage,
    do: [threshold: 90, ignore_modules: [DpExchange.Webull.Vendor.WebSockex]]

  defp aliases do
    [quality: ["format --check-formatted", "credo --strict", "dialyzer", "sobelow --config"]]
  end

  defp dialyzer do
    [plt_add_apps: [:mix, :ex_unit], plt_file: {:no_warn, "priv/plts/dialyzer.plt"}]
  end

  defp preferred_cli_env, do: [quality: :test]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bcatherall"],

      # `files:` belongs HERE, not at the project level. Hex reads `package[:files]`; a
      # `files:` in `project/0` is silently ignored and Hex ships its own defaults —
      # which puts `priv/plts/dialyzer.plt` in the tarball and leaves out anything you
      # meant to add. Nothing warns. Inspect `mix hex.build` before every publish.
      #
      # `priv/` is absent because the only thing in it is the dialyzer PLT.
      # `config/` is absent: it governs this package's own dev and test, never a
      # consumer's.
      files: [
        "lib",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "AGENTS.md",
        "usage-rules.md",
        "docs/reference"
      ]
    ]
  end

  defp docs do
    [
      main: "DpExchange.Webull",
      extras: ["README.md", "CHANGELOG.md", "usage-rules.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp usage_rules, do: [file: "AGENTS.md", usage_rules: [:usage_rules]]
end
