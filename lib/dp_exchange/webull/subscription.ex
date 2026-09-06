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

  `["SNAPSHOT", "QUOTE"]` is **confirmed live** — the same pair the prior in-repo client
  accepted for months and issue #19 measured directly. `TICK` joined the default so a
  plain `subscribe/2` delivers `Core.Types.Trade` the same way it already delivers
  `Quote` and `TopOfBook`, with no venue-shaped option a consumer has to learn — but
  its inclusion here is **read from `streaming-api.md`'s topic table, not yet measured
  against the live venue** the way the other two were. If the venue answers `TICK`
  differently from what the table promises, that will surface as `Feed`'s existing
  generic-subscribe-failure handling — see its moduledoc — the same as any other
  refusal this module hands back.

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
  """

  alias DpExchange.Core.HttpClient
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
        # venue actually accepted for months from the prior in-repo client; `TICK` is
        # read from the vendor's own topic table and not yet measured live — see the
        # moduledoc.
        "sub_types" => Keyword.get(opts, :sub_types, ["SNAPSHOT", "QUOTE", "TICK"])
      })

    request = %{
      path: path,
      query_params: %{},
      body: body,
      host: host,
      timestamp: Auth.timestamp(),
      nonce: Auth.nonce()
    }

    with {:ok, headers} <- Auth.headers(request, credentials) do
      url = Environment.rest_url(environment) <> path

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
