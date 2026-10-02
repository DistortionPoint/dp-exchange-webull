defmodule DpExchange.Webull.Subscription do
  @moduledoc """
  The HTTP half of subscribing — internal.

  Webull steers an MQTT stream with REST calls. `POST /market-data/streaming/subscribe`
  names the `session_id` that the MQTT connection registered as its client id, and the
  broker begins publishing to that session.

  Split across two protocols like this, the failure modes are unusual and worth naming:

  - **A 200 here does not mean data is arriving.** It means the venue accepted the request.
    Whether anything is published depends on the MQTT session being up and carrying the
    same id. That is why `coverage/1` reports only what *arrived* — on this venue, "asked",
    "accepted" and "delivering" are three different moments.
  - **A session id mismatch fails silently in the most expensive way**: the HTTP call
    succeeds, the broker publishes to a session nobody is listening on, and the socket sits
    connected and idle. There is no error anywhere. One generated id, used for both, is the
    only defence.

  Every call is signed — this venue has no anonymous endpoints.

  **`sub_types` is uppercase (`SNAPSHOT`, `QUOTE`, `TICK`) and is not the MQTT topic
  namespace.** The subscribe request body's subtype field and the MQTT topics a connected
  session receives on (`quote`, `snapshot`, `tick` — lowercase, see `streaming-api.md`)
  look like the same vocabulary and are not: they are two different fields on two
  different protocols. Sending the lowercase topic names here got every subscribe
  rejected `HTTP 417 UNSUPPORTED_SUB_TYPE` — DpCryptoManagement's issue #19, filed right
  after #18 unblocked the request enough to reach this validation for the first time.

  `["SNAPSHOT", "QUOTE"]` is **confirmed live**, the same pair the prior in-repo client
  accepted for months and issue #19 measured directly. The default is that pair plus
  `TICK`.

  **`TICK` is requested, because it is the one trade-tape route this venue documents for
  crypto.** It joined the default on 2026-09-06, read from `streaming-api.md`'s topic table
  ("Stocks, Futures and Crypto"). On 2026-09-29, with `Socket` reporting every way a tick can
  be dropped, a consumer on ~325 us-crypto symbols measured no `Trade` and no drop notice
  (dp-exchange-core issue #40), and it left the default. It came back on 2026-10-02
  (dp_exchange_webull issue #7): the venue accepted the request carrying it, so asking costs
  nothing, while not asking guarantees a trade never arrives. `Socket` decodes every `tick`
  into a `Core.Types.Trade`, and reports any it cannot. `:trades` stays out of
  `capabilities/0` until a run shows ticks arriving, because a declaration is a claim about
  what was measured.

  #7 also asked whether that measurement could be trusted. The record answers both of its
  doubts:

  * **`TICK` was in the measured request, and the venue accepted it.** #40's own body records
    `sub_types: ["SNAPSHOT", "QUOTE", "TICK"]`. A refused sub-type fails the whole request
    (`HTTP 417 UNSUPPORTED_SUB_TYPE`, issue #19), so if `TICK` had been refused no quote would
    have arrived either. Quotes from that same request arrived, about 20,000 in 3 minutes.
  * **The session was serving.** The same 20,000 quotes in 3 minutes came on it. The
    "Permission grabbed" churn in that consumer's log was real, but it did not stop the
    session delivering every other topic it was subscribed to.

  What the record lacks is the venue's response body to that subscribe, and a run on a
  session with no competing grab. Both need credentials this repo never holds. Requesting
  `TICK` by default makes every consumer's run that re-measurement:
  every way a `tick` can be dropped raises a `:data_quality` notice, so
  a run with no `Trade` and no notice is the measurement repeated.

  ## `INVALID_SYMBOL` names the offending symbols, and this module hands them back

  Rejection here is per-**request**, not per-symbol: one symbol the venue's streaming
  category does not carry fails the *entire* batch, and the venue answers with
  `{"error_code" => "INVALID_SYMBOL", "message" => "The symbols does not exist in the
  category. [SYM1, SYM2, ...]"}` — measured from `Feed`'s own resubscribe logs
  (DpCryptoManagement's issue #24): 17 of one consumer's 342 symbols named this way, every
  60-second resubscribe tick, forever, because nothing downstream could act on the answer.
  Before this, that whole response collapsed into the generic `{:exchange_error, :webull,
  "HTTP 417: ..."}` string below — a caller could log it, and could not pattern-match a
  single symbol out of it.

  `invalid_symbols/1` parses the bracketed list out of `message` and this function converts
  every entry back to CANONICAL form before it returns — no venue-shaped symbol string is
  allowed to escape this module. `Feed` (not this module) decides what happens to a rejected
  symbol; this module's only job, same as `:oversubscribed` below, is to make the venue's
  answer something a caller can act on rather than only read.

  **A message the parser cannot attribute to any symbol is not treated as naming zero
  symbols.** It falls through to the same opaque `{:exchange_error, ...}` shape a 417 with
  no recognisable list already produced — inventing an empty exclusion list from a
  rejection nobody could attribute would look like "nothing was rejected" to `Feed`, which
  is the one interpretation this response never supports.

  ## Two more divergences between `subscribe.md` and this request, neither changed here

  `subscribe.md:140-196` marks `category`, `grab`, `session_id` and `sub_types` all
  required, and its `category` enum is `["US_STOCK", "US_ETF"]` only — `US_CRYPTO`, which
  this body sends, is not a member of it. That is the SAME category-vs-page conflict the
  moduledoc's `["SNAPSHOT", "QUOTE"]` note already resolves for `sub_types`, and it
  resolves the same way for the same reason: `US_CRYPTO` is confirmed live (the same
  DpCryptoManagement issue #19 read), so the wire stays `US_CRYPTO` and the page's
  narrower enum is recorded as wrong, or at least incomplete, rather than acted on.

  `grab` ("Whether to grab snapshot data, true/false") is different in kind: it is a real
  gap, not a resolved one. The page marks it required and gives it no documented default,
  and its one-line description says nothing about what "grab" means beyond the two literal
  values — there is no worked example, no note on what a subscribe without it does instead,
  and nothing elsewhere in this repository's captured pages defines the term further.
  Sending either `"true"` or `"false"` here would be **guessing which of two values is
  safe** on a required field this package cannot read the semantics of, which is exactly
  the substitution `CLAUDE.md`'s fail-closed rule exists to prevent — and the live evidence
  says the guess is not even needed: `["SNAPSHOT", "QUOTE"]` has subscribed successfully for
  months without `grab` ever being sent (the same issue #19 measurement). So the wire is
  left unchanged, `grab` omitted, and this paragraph is the record of the divergence rather
  than a silent one: measured-live behaviour (works, without `grab`) against the
  documentation (requires it, undefined how). Sending a guessed value on a *working*
  request risks breaking it to satisfy a schema this package cannot verify; that trade is
  refused the same way a request would be if the direction were reversed.
  """

  alias DpExchange.Core.{Config, HttpClient}
  alias DpExchange.Webull.{Auth, Environment, SymbolFormat}

  @subscribe_path "/market-data/streaming/subscribe"
  @unsubscribe_path "/market-data/streaming/unsubscribe"

  @doc """
  Starts publication for `symbols` on the MQTT session registered under `session_id`.

  An empty symbol list is `:ok` without a request: asking the venue to subscribe to
  nothing spends a call from a budget this venue is already the tightest on.
  """
  @spec subscribe(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(session_id, symbols, opts), do: post(@subscribe_path, session_id, symbols, opts)

  @doc "Stops publication for `symbols`."
  @spec unsubscribe(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def unsubscribe(session_id, symbols, opts),
    do: post(@unsubscribe_path, session_id, symbols, opts)

  defp post(_path, _session_id, [], _opts), do: :ok

  defp post(path, session_id, symbols, opts) do
    credentials = Keyword.get(opts, :credentials, %{})
    environment = Environment.resolve(opts)
    host = Environment.host(environment)

    body =
      Jason.encode!(%{
        "session_id" => session_id,
        "category" => "US_CRYPTO",
        "symbols" => Enum.map(symbols, &SymbolFormat.to_exchange_symbol/1),
        # Uppercase, and NOT the same strings as the MQTT topic names (`quote`,
        # `snapshot`, `tick` — see streaming-api.md). Confirmed live by
        # DpCryptoManagement's issue #19: lowercase values here get every subscribe
        # rejected `HTTP 417 UNSUPPORTED_SUB_TYPE`. `SNAPSHOT` and `QUOTE` are what the
        # venue actually accepted for months from the prior in-repo client. `TICK` left the
        # default on 2026-09-29 (dp-exchange-core issue #40) and came back on 2026-10-02
        # (dp_exchange_webull issue #7) — see the moduledoc.
        "sub_types" => Config.opt(opts, :sub_types, ["SNAPSHOT", "QUOTE", "TICK"])
      })

    request = %{path: path, query_params: %{}, body: body, host: host}
    url = Environment.rest_url(environment) <> path

    # Signed per attempt: a `Core.HttpClient` retry carrying the first attempt's nonce is a
    # replay the venue refuses. A repeated subscribe of the same symbols to the same session
    # is harmless, so this call keeps its retries — see `Rest`'s `signer/2`.
    headers = fn ->
      request
      |> Map.merge(%{timestamp: Auth.timestamp(), nonce: Auth.nonce()})
      |> Auth.headers(credentials)
    end

    case HttpClient.request(:post, url, headers, body, request_opts(opts)) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 417, body: %{"error_code" => "TOO_MANY_SYMBOLS_SUBSCRIPTION"}}} ->
        # Named separately from the generic exchange_error below: this is the venue's
        # per-session subscription ceiling, a capacity answer this package's own Feed
        # can act on (move the symbols to another shard), not a caller-visible failure
        # in the making — collapsing it into an opaque string would leave the caller
        # with nothing to pattern-match to recover automatically.
        {:error, :oversubscribed}

      {:ok, %{status: 417, body: %{"error_code" => "INVALID_SESSION"} = response_body}} ->
        # The session this subscribe is addressed to no longer exists venue-side. Named
        # separately from the generic `exchange_error` below for the same reason
        # `:oversubscribed` and `:invalid_symbols` are: it is an answer `Feed` can ACT on,
        # and it is the one answer where retrying the identical call is guaranteed never
        # to work.
        #
        # dp-exchange-core issue #30: it collapsed into the opaque string below, `Feed`
        # retried the same dead session id every 60 seconds, and four shards stayed dark
        # for fourteen hours — 1,479 identical warnings — until a human restarted the
        # feed. The venue was handing out working sessions the whole time; only the code
        # path to ask for one was missing.
        #
        # The session id is carried out of the message so a caller can tell WHICH session
        # died, which matters on a sharded venue where three of four may be fine. When it
        # cannot be parsed the error still says `:invalid_session` — the recovery does not
        # depend on the id, and refusing to name the failure because one detail is missing
        # would put us straight back in the fourteen-hour loop.
        {:error, {:invalid_session, session_id_from(response_body)}}

      {:ok, %{status: 417, body: %{"error_code" => "INVALID_SYMBOL"} = response_body}} ->
        # See the moduledoc's "`INVALID_SYMBOL` names the offending symbols" —
        # DpCryptoManagement's issue #24.
        case invalid_symbols(response_body) do
          {:ok, native_symbols} ->
            {:error,
             {:invalid_symbols, Enum.map(native_symbols, &SymbolFormat.to_canonical_symbol/1)}}

          :error ->
            {:error, {:exchange_error, :webull, "HTTP 417: #{inspect(response_body)}"}}
        end

      {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
        {:error, {:refused, status, response}}

      {:ok, %{status: status, body: response}} ->
        {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(response)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Pulls the bracketed, comma-separated symbol list out of an `INVALID_SYMBOL` body's
  # `message` — `"The symbols does not exist in the category. [BNBUSD]"` for one symbol,
  # `"... [GYENUSD, GALAUSD, ...]"` for several — measured against the real venue response
  # (DpCryptoManagement's issue #24). Every symbol named here is still venue-shaped
  # (native); the caller above converts to canonical before this module returns anything.
  #
  # `:error` — never `{:ok, []}` — for anything the regex cannot find a bracketed,
  # non-empty list in. See the moduledoc: a rejection this module cannot attribute to a
  # symbol must fall through to the opaque `exchange_error` shape, not be reported as
  # zero rejected symbols.
  @invalid_symbol_list ~r/\[([^\]]+)\]/

  # `"Mqtt connection not exist for session:3c4fdabd54097164fbd0f66d95743aae"` — the venue
  # names the dead session in prose, so this reads it out of prose. Deliberately tolerant:
  # `nil` when the shape changes, never a raise and never a guess, because the caller's
  # recovery (reopen the shard) does not depend on the id and must not be blocked by a
  # message this parser has not seen before.
  defp session_id_from(%{"message" => message}) when is_binary(message) do
    case Regex.run(~r/session:\s*([A-Za-z0-9_-]+)/, message) do
      [_match, session_id] -> session_id
      nil -> nil
    end
  end

  defp session_id_from(_no_message), do: nil

  defp invalid_symbols(%{"message" => message}) when is_binary(message) do
    case Regex.run(@invalid_symbol_list, message) do
      [_match, listed] ->
        case listed
             |> String.split(",")
             |> Enum.map(&String.trim/1)
             |> Enum.reject(&(&1 == "")) do
          [] -> :error
          symbols -> {:ok, symbols}
        end

      nil ->
        :error
    end
  end

  defp invalid_symbols(_other), do: :error

  # `:rate_limit_blocking` is forwarded, never defaulted, here — see `Feed`'s moduledoc
  # ("The resubscribe timer must never fail-fast", DpCryptoManagement's issue #23). This
  # module has no opinion on whether a caller can afford to wait; `Feed` is the one
  # caller that both knows it can (the resubscribe timer) and says so explicitly.
  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :limiter,
      :timeout,
      :retry_attempts,
      :log_requests,
      :plug,
      :req_adapter,
      :rate_limit_blocking
    ])
    |> Keyword.merge(provider: :webull, raw_status: true)
  end
end
