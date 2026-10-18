defmodule DpExchange.Webull.Options do
  @moduledoc """
  The options each facade function reads, in one place, and the check that refuses the rest.

  A misspelt `limt:` that is silently ignored returns a plausible answer to a different
  question than the caller asked, which is the "nearby substitute where there should be an
  error" this family exists to avoid. Every `DpExchange.Webull` function that takes a keyword
  `opts`, and its `DpExchange.Webull.Fake` twin, calls this module at the boundary: before
  anything is sent, before the facade adds its own `:limiter`, and after the positional
  arguments (symbol, order id, watchlist id, request) have been checked.

  ## What a function may be given

  A shared transport key (`DpExchange.Core.Options.transport_options/0`) is accepted only
  where the call reads it, and every one accepted is forwarded to `Core.HttpClient`.

    * A call that sends a request allows every shared key **but `:base_url`** (no call reads
      it; the hosts come from `:environment`), plus the keys in `own_keys/1`.
      `oauth_token/3` also refuses `:credentials`: the client id and secret are arguments.
    * A write that is always sent exactly once (`place_order/3`, `place_orders/3`,
      `cancel_order/3`, `replace_order/4`, the watchlist writes, `create_token/1` and
      `oauth_token/3`) reads neither `:retry_attempts` nor `:retry_delay`: both are
      `{:error, {:unknown_option, key}}`, whatever the value, before anything is sent.
    * `get_fees/2`, `coverage/1`, `wanted/1`, `coverage_by_kind/1` and `subscribe_notices/1`
      send no request and open no socket: they allow `:credentials` (exempt, a consumer hands
      one set to every call) and their own keys, so `timeout: 5_000` is refused.
    * `streaming?/1` and `live?/1` allow `:credentials` and `:environment`, which they
      resolve, and nothing else.

  A refused key is `{:error, {:unknown_option, key}}`. The table below is the second half,
  and the only place it is written down:
  `check/3` reads it, `DpExchange.Webull` and `DpExchange.Webull.Fake` both call `check/3`
  (or one of the positional helpers), so the two cannot disagree.

  A key that the code reads **only to refuse it** is still in the table, because the more
  specific answer is the useful one: `:limit` on `get_order_book/2` is
  `{:error, {:unsupported_option, :limit}}` (levels per side are `:depth`), `:since` on
  `get_trades/2` likewise, `:real_time` on the bars (renamed `:include_partial`), `:symbols`
  on `update_watchlist/2` is `{:error, :membership_not_updatable_here}`.

  Two calls take part of their keys from the argument that names the endpoint, so the table
  cannot hold all of them: `get_fundamental/3` (the fundamentals kind) and `get_screener/2`
  (the screener). `Rest.fundamental_option_keys/1` and `Rest.screener_option_keys/1` answer
  those and are passed as `extra` to `check/3`; `check_fundamental/3` and `check_screener/2`
  do both steps. `get_financials/3` is fixed: all four statement kinds take the same keys.

  ## What it answers

    * `:ok`
    * `{:error, {:unknown_option, key}}` - the first key (in the caller's order) not allowed
    * `{:error, {:invalid_options, opts}}` - `opts` is not a keyword list

  `check!/2` is the same check for a plain-value read with no error channel (`coverage/1`,
  `wanted/1`, `coverage_by_kind/1`, `streaming?/1`, `live?/1`): it raises `ArgumentError`.

  A function that answers `Venue.not_supported()` is not in the table and keeps doing so
  whatever it is given.
  """

  alias DpExchange.Core.Options, as: CoreOptions
  alias DpExchange.Webull.Rest

  # `:category` selects the market a snapshot is read from; the two hours flags are sent on
  # the stock snapshot only.
  @snapshot [:category, :extended_hours, :overnight]

  # `:since` / `:until` are the history window of `get_orders/2`; `:history` picks the endpoint.
  @orders [:account_id, :history, :since, :until]

  # The cash-activity endpoint's own filters, shared by `get_transfers/2` and
  # `get_transactions/2` (same endpoint).
  @activity [:account_id, :activity_types, :start, :end]

  # The fundamentals pass-through options of the statement endpoints (all four kinds take
  # `type` and `count`).
  @statement [:category, :type, :count]

  # What narrows or pages the event-contract market listing.
  @event_markets [:series_symbol, :event_symbol, :symbols, :expiring_after, :pagination_key]

  # The keys each function reads beyond `DpExchange.Core.Options.transport_options/0`. Keys
  # that select an account, a feed or an environment count: `:account_id`, `:feed`.
  @own_keys %{
    # market data
    get_price: @snapshot,
    get_prices: @snapshot,
    get_top_of_book: @snapshot,
    get_historical_prices: [:category, :limit, :include_partial, :real_time, :sessions],
    get_symbols: [:category],
    list_instruments: [:category],
    get_order_book: [:category, :depth, :limit, :overnight, :extended_hours],
    get_trades: [:category, :limit, :since, :sessions],
    get_volume_profile: [:category, :session, :count],
    get_auction_imbalance: [:auction, :history],
    quantization: [],
    # account and orders
    get_accounts: [],
    get_fees: [],
    get_balances: [:account_id],
    get_positions: [:account_id],
    get_orders: @orders,
    get_order: [:account_id],
    cancel_order: [:account_id],
    place_order: [:account_id],
    place_orders: [:account_id],
    preview_order: [:account_id],
    replace_order: [:account_id, :instrument_type, :order_type],
    get_transfers: @activity,
    get_transactions: @activity,
    # streaming
    subscribe: [:to, :feed, :sub_types],
    unsubscribe: [:feed, :sub_types],
    update_symbols: [:feed, :sub_types],
    subscribe_notices: [:to, :feed],
    coverage: [:feed],
    wanted: [:feed],
    coverage_by_kind: [:feed],
    streaming?: [],
    live?: [],
    # options, futures and event contracts
    get_option_chain: [:expiry, :strike],
    get_option_expirations: [:expiry, :strike],
    list_futures_contracts: [:symbols, :code, :status],
    list_futures_product_classes: [],
    list_event_categories: [],
    list_event_series: [:category, :symbols, :pagination_key],
    list_event_events: [:series_symbol, :symbols, :status],
    list_event_markets: @event_markets,
    get_event_trades: [:limit],
    get_event_order_book: [:depth],
    # watchlists
    list_watchlists: [],
    get_watchlist: [],
    create_watchlist: [:sort, :category],
    update_watchlist: [:name, :sort, :symbols],
    delete_watchlist: [],
    add_watchlist_instruments: [:category],
    remove_watchlist_instruments: [:category],
    sort_watchlist_instruments: [:sorts, :category],
    # reference data
    get_financials: @statement,
    get_corporate_events: [:symbol, :kind, :category],
    get_filings: [:category],
    get_news: [:symbols, :category, :sentiment, :limit],
    get_screener: [],
    get_fundamental: [],
    # tokens
    create_token: [],
    check_token: [],
    oauth_token: [:code, :refresh_token, :oauth_url]
  }

  @doc """
  The keys `function` reads beyond `DpExchange.Core.Options.transport_options/0`.

  Raises `KeyError` for a function that has no entry, which is a bug in the caller.
  """
  @spec own_keys(atom()) :: [atom()]
  def own_keys(function), do: Map.fetch!(@own_keys, function)

  @doc """
  Checks `opts` against the keys `function` may be given.

  `extra` adds keys that depend on an argument (`get_fundamental/3`'s kind, `get_screener/2`'s
  name). Answers `:ok`, `{:error, {:unknown_option, key}}` or
  `{:error, {:invalid_options, opts}}`.
  """
  @spec check(atom(), term(), [atom()]) ::
          :ok | {:error, {:unknown_option, atom()} | {:invalid_options, term()}}
  def check(function, opts, extra \\ []) do
    CoreOptions.check(opts, transport(function) ++ own_keys(function) ++ extra)
  end

  # The transport keys `function` reads, from `DpExchange.Core.Options.transport_options/0`.
  #
  # A call that sends a request (everything not listed below) reads every shared key but
  # `:base_url`: `Rest.request_opts/1` (and `Subscription`'s copy for the subscribe family)
  # forwards `:limiter`, `:rate_limit_blocking`, `:weight`, `:timeout`, `:retry_attempts`,
  # `:retry_delay`, `:max_retry_after_s`, `:max_body_bytes`, `:log_requests`, `:plug`,
  # `:adapter` and `:req_adapter` to `Core.HttpClient`; `:credentials` and `:environment`
  # are read by the call itself.
  #
  #   * `:base_url` - read by no call: the hosts come from `Environment`, and the one other
  #     URL, `oauth_token/3`'s, is `:oauth_url`. Accepting a `base_url:` that does nothing
  #     would let a caller believe a signed request had been redirected when it went to the
  #     venue's own host.
  #   * `:credentials` on `oauth_token/3` - the client id and secret are arguments; a
  #     credential map there changes nothing.
  #
  # A call that sends no request reads no HTTP key at all. `:credentials` stays allowed on
  # them (core's design exemption: a consumer hands one credential set to every call, and
  # one a call does not need changes no answer). `:environment` is kept where it really
  # selects something: `streaming?/1` and `live?/1` resolve it, and nothing else here does.
  @no_request [:get_fees, :coverage, :wanted, :coverage_by_kind, :subscribe_notices]
  @environment_only [:streaming?, :live?]

  # **A call that is always sent exactly once reads neither `:retry_attempts` nor
  # `:retry_delay`**, so both are refused (`{:unknown_option, key}`, before anything is
  # sent) rather than accepted and overwritten. The venue documents no idempotency key for
  # any of these writes, so `Rest` sends each with `retry_attempts: 1` whatever the caller
  # passes; a table that still allowed the key let `retry_attempts: 3` read as "retry this
  # order" and do nothing. `oauth_token/3` is a single-use token refresh: a retried
  # refresh token is a spent one.
  @sent_once [
    :place_order,
    :place_orders,
    :cancel_order,
    :replace_order,
    :create_watchlist,
    :update_watchlist,
    :delete_watchlist,
    :add_watchlist_instruments,
    :remove_watchlist_instruments,
    :sort_watchlist_instruments,
    :create_token
  ]
  @no_retry_keys [:retry_attempts, :retry_delay]

  defp transport(function) when function in @no_request, do: [:credentials]
  defp transport(function) when function in @environment_only, do: [:credentials, :environment]

  defp transport(function) when function in @sent_once,
    do: CoreOptions.transport_options() -- [:base_url | @no_retry_keys]

  defp transport(:oauth_token),
    do: CoreOptions.transport_options() -- [:base_url, :credentials | @no_retry_keys]

  defp transport(_function), do: CoreOptions.transport_options() -- [:base_url]

  @doc """
  `check/3` for a call with no error channel: raises `ArgumentError` instead of answering.

  For `coverage/1`, `wanted/1`, `coverage_by_kind/1`, `streaming?/1` and `live?/1`, whose
  specs are a map, a list and a boolean. Returning an empty map for a misspelt `feed:` would
  read as "nothing is arriving" and send the caller to debug the stream.
  """
  @spec check!(atom(), term()) :: :ok
  def check!(function, opts) do
    case check(function, opts) do
      :ok ->
        :ok

      {:error, {:unknown_option, key}} ->
        raise ArgumentError, "#{function}/1 does not take the option #{inspect(key)}"

      {:error, {:invalid_options, bad}} ->
        raise ArgumentError, "#{function}/1 takes a keyword list, got: #{inspect(bad)}"
    end
  end

  @doc """
  The symbol is checked first, then the options: `{:error, {:invalid_symbol, symbol}}` wins
  over an unknown option, as positional arguments do in every venue of this family.
  """
  @spec check_symbol(atom(), term(), term()) :: :ok | {:error, term()}
  def check_symbol(function, symbol, opts) do
    with :ok <- Rest.validate_symbol(symbol), do: check(function, opts)
  end

  @doc """
  The order id is checked first (`{:error, {:invalid_order_id, id}}`), then the options.
  """
  @spec check_order_id(atom(), term(), term()) :: :ok | {:error, term()}
  def check_order_id(function, id, opts) do
    with :ok <- Rest.validate_order_id(id), do: check(function, opts)
  end

  @doc """
  The watchlist id is checked first (`{:error, {:invalid_watchlist_id, id}}`), then the
  options.
  """
  @spec check_watchlist_id(atom(), term(), term()) :: :ok | {:error, term()}
  def check_watchlist_id(function, id, opts) do
    with :ok <- Rest.validate_watchlist_target(:id, id), do: check(function, opts)
  end

  @doc """
  The token is checked first (`{:error, {:invalid_field, :token}}`; the value is a credential,
  so the field is named and the value is not echoed), then the options.
  """
  @spec check_token(term(), term()) :: :ok | {:error, term()}
  def check_token(token, opts) do
    with :ok <- text_field(:token, token), do: check(:check_token, opts)
  end

  @doc """
  `client_id` and then `client_secret` are checked first (`{:error, {:invalid_field, field}}`,
  never echoing the value), then the options.
  """
  @spec check_oauth(term(), term(), term()) :: :ok | {:error, term()}
  def check_oauth(client_id, client_secret, opts) do
    with :ok <- text_field(:client_id, client_id),
         :ok <- text_field(:client_secret, client_secret) do
      check(:oauth_token, opts)
    end
  end

  defp text_field(_field, value) when is_binary(value), do: :ok
  defp text_field(field, _value), do: {:error, {:invalid_field, field}}

  @doc """
  The keys a `get_fundamental/3` of `kind` may be given beyond the transport ones, or the
  unknown-kind refusal. Checked first, as the kind names the endpoint.
  """
  @spec check_fundamental(term(), term(), term()) :: :ok | {:error, term()}
  def check_fundamental(kind, symbol, opts) do
    with {:ok, keys} <- Rest.fundamental_option_keys(kind),
         :ok <- Rest.validate_symbol(symbol) do
      check(:get_fundamental, opts, keys)
    end
  end

  @doc """
  The keys a `get_screener/2` of `name` may be given beyond the transport ones, or the
  unknown-screener refusal. Checked first, as the name names the endpoint.
  """
  @spec check_screener(term(), term()) :: :ok | {:error, term()}
  def check_screener(name, opts) do
    with {:ok, keys} <- Rest.screener_option_keys(name) do
      check(:get_screener, opts, keys)
    end
  end
end
