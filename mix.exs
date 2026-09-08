defmodule DpExchangeWebull.MixProject do
  use Mix.Project

  # SEED, not a release. CI increments the last segment of whatever it finds here, so
  # `0.1.0` first publishes as `0.1.1`. Hand-editing this to `0.2.0` is how a breaking
  # change is signalled. The bump script matches the attribute assignment below by its
  # exact literal form — do not reformat it, and do not repeat that form anywhere else
  # in this file, comments included, or the script will rewrite the wrong line.
  @version "0.2.21"
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
      {:dp_exchange_core, "~> 0.1.68"},

      # This venue's own transport. Core ships no transport library at any strength —
      # a venue that speaks WebSocket ships what it needs to speak it.
      #
      # `~> 0.5.1`, not `~> 0.5`: `Socket.disconnect/2` calls `WebSockex.send_frame/3`,
      # and the third argument — the send timeout — only exists from 0.5.1, not 0.5.0.
      # Under `~> 0.4` this package resolved 0.5.1 locally and so compiled and passed,
      # while a consumer who resolved 0.4.x got `:undef` at the call. DpCryptoManagement
      # hit exactly that on 2026-09-08. Arity is only checked when the function runs, so
      # it shipped as a compile warning rather than an error, and only on a path nothing
      # exercised.
      #
      # The floor was first corrected to `~> 0.5`, on the belief that the argument landed
      # somewhere in the 0.5 line. `script/check_dependency_floor.sh` (added the same day,
      # to close exactly this blind spot family-wide) resolved that floor for real and
      # found `WebSockex.send_frame/3 is undefined or private` against 0.5.0 itself —
      # `send_frame/3` is new in 0.5.1, one patch later than the first fix assumed, and
      # `~> 0.5` still permitted the version that lacks it. Confirmed by reading both
      # resolved sources directly: 0.5.0's `lib/websockex.ex` defines only `send_frame/2`;
      # 0.5.1's defines `send_frame(client, frame, timeout \\ 5_000)`. The lesson this
      # family had already drawn — a "corrected" floor still needs to be resolved to prove
      # it, not just reasoned about — applied to its own correction within the same day.
      #
      # `send_frame/2` works on both and is the WRONG fix: it takes WebSockex's own
      # 5_000ms default, where `@disconnect_timeout_ms` is deliberately 500ms because
      # `disconnect/2` runs inside `Feed.terminate/2`, under a supervisor's shutdown
      # budget. Ten times the wait during shutdown is not a free compatibility win, so the
      # honest fix is to require the version whose API this package actually uses.
      {:websockex, "~> 0.5.1"},
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

  defp test_coverage, do: [threshold: 90, ignore_modules: []]

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
