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
        # The venue's own topic names. `quote` is the book, `snapshot` the last price.
        "sub_types" => Keyword.get(opts, :sub_types, ["snapshot", "quote"])
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

        {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
          {:error, {:refused, status, response}}

        {:ok, %{status: status, body: response}} ->
          {:error, {:exchange_error, :webull, "HTTP #{status}: #{inspect(response)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :webull, raw_status: true)
  end
end
