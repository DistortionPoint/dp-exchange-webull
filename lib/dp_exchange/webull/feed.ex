defmodule DpExchange.Webull.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal, and the place where its two transports
  are joined.

  ## Subscribing here is two operations on two protocols

  Market data arrives over **MQTT**; subscriptions are **HTTP** calls. They are joined by
  one value: the `session_id` this feed generates, registers as the MQTT client id, and
  then names in every HTTP subscribe.

  A consumer calls `subscribe/3` with symbols. It never learns that a socket was dialled,
  that an HTTP call followed, or that the two had to agree on an identifier — which is the
  facade doing precisely what D12 asks of it, on the venue where it costs the most to
  deliver.

  ## Re-subscribing after a reconnect is this package's job

  > If the connection is dropped due to network issues, previous subscriptions are **not**
  > automatically restored. You must re-subscribe after reconnecting.

  So a reconnect is followed by a replay of everything wanted. A consumer that had to
  notice reconnects and replay its own subscriptions would be doing the venue's
  bookkeeping through an interface designed to hide reconnects entirely.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives** — not when it is
  subscribed, and not when the HTTP subscribe returns 200. On this venue those are three
  genuinely different moments, and only the last one means data.

  ## One connection, because five is the ceiling and one is enough

  The venue allows five concurrent connections per App Key and pushes at most three
  messages per second per connection. This feed opens **one**. Sharding to raise the
  message ceiling is a change to make when a measurement demands it, and it can never
  exceed five — a consumer cannot cause a sixth socket, because a consumer cannot ask for
  sockets at all.
  """

  use GenServer

  alias DpExchange.Core.Notice
  alias DpExchange.Webull.{Environment, Socket, Subscription}

  @frame_window_ms 5_000
  @call_timeout @frame_window_ms * 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    GenServer.call(
      feed,
      {:subscribe, symbols, Keyword.get(opts, :to, self()), opts},
      @call_timeout
    )
  end

  @spec unsubscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def unsubscribe(feed, symbols, opts),
    do: GenServer.call(feed, {:unsubscribe, symbols, opts}, @call_timeout)

  @spec update_symbols(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def update_symbols(feed, symbols, opts),
    do: GenServer.call(feed, {:update_symbols, symbols, opts}, @call_timeout)

  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed), do: GenServer.call(feed, :coverage)

  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server -------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       # Generated once and used as BOTH the MQTT client id and the HTTP subscribe's
       # session id. The venue disconnects an older connection presenting the same id, so
       # two instances sharing one would take turns killing each other, each looking
       # healthy in isolation.
       session_id: Keyword.get_lazy(opts, :session_id, &generate_session_id/0),
       socket_opts: Keyword.take(opts, [:url, :environment]),
       # Retained so a reconnect can replay the subscription. The venue restores
       # nothing, and a replay needs credentials — so a consumer that wants
       # automatic recovery hands them to the tree at start, exactly as the other
       # venues in this family do. Per-call options still override these.
       resubscribe_opts: Keyword.take(opts, [:credentials, :environment, :limiter, :plug]),
       socket: Keyword.get(opts, :socket),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       delivering: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber, opts}, _from, state) do
    environment = Environment.resolve(Keyword.merge(state.socket_opts, opts))

    if Environment.streaming?(environment) do
      state = %{
        state
        | subscribers: MapSet.put(state.subscribers, subscriber),
          wanted: MapSet.union(state.wanted, MapSet.new(symbols))
      }

      case ensure_socket(state, environment) do
        {:ok, state} ->
          # Remember what a replay needs. Without this, a reconnect re-subscribes with no
          # credentials and fails — the venue restores nothing, so the promise that a
          # consumer never sees a reconnect would quietly stop being true.
          state = %{state | resubscribe_opts: replayable(opts, state)}
          {:reply, Subscription.subscribe(state.session_id, symbols, opts), state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      # UAT has REST but no broker — `mqtt-uat.webullbroker.com` is NXDOMAIN. Falling back
      # to the production stream would hand a consumer real market data while it believed
      # it was testing.
      {:reply, {:error, {:streaming_unavailable, environment}}, state}
    end
  end

  def handle_call({:unsubscribe, symbols, opts}, _from, state) do
    {:reply, Subscription.unsubscribe(state.session_id, symbols, opts), drop(state, symbols)}
  end

  def handle_call({:update_symbols, symbols, opts}, _from, state) do
    wanted = MapSet.new(symbols)
    added = state.wanted |> then(&MapSet.difference(wanted, &1)) |> MapSet.to_list()
    removed = wanted |> then(&MapSet.difference(state.wanted, &1)) |> MapSet.to_list()

    state = %{state | wanted: wanted, delivering: Map.take(state.delivering, symbols)}

    result =
      with :ok <- Subscription.unsubscribe(state.session_id, removed, opts) do
        Subscription.subscribe(state.session_id, added, opts)
      end

    {:reply, result, state}
  end

  def handle_call(:coverage, _from, state) do
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :webull, %Notice{kind: :link_up}} = message, state) do
    # The venue restores nothing on reconnect, so a fresh link means replaying everything
    # wanted. Doing it here is the whole reason a consumer never sees a reconnect.
    resubscribe(state)
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :webull, %Notice{}} = message, state) do
    fan_out(state.notice_subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :webull, quote_struct} = message, state) do
    fan_out(state.subscribers, message)

    {:noreply,
     %{
       state
       | delivering: Map.put(state.delivering, quote_struct.symbol, :os.system_time(:millisecond))
     }}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp resubscribe(%{wanted: wanted} = state) do
    case MapSet.to_list(wanted) do
      [] -> :ok
      symbols -> Subscription.subscribe(state.session_id, symbols, state.resubscribe_opts)
    end
  end

  defp ensure_socket(%{socket: socket} = state, _environment) when is_pid(socket),
    do: {:ok, state}

  defp ensure_socket(state, environment) do
    opts =
      state.socket_opts
      |> Keyword.put_new(:url, Environment.streaming_url(environment))
      |> Keyword.merge(
        subscriber: self(),
        session_id: state.session_id,
        app_key: Keyword.get(state.socket_opts, :app_key, "")
      )

    case Socket.start_link(opts) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(state, symbols) do
    %{
      state
      | wanted: MapSet.difference(state.wanted, MapSet.new(symbols)),
        delivering: Map.drop(state.delivering, symbols)
    }
  end

  # Only what a replay needs, and per-call values win over the ones the tree started
  # with — a caller that named credentials for one subscribe meant them for its replay.
  defp replayable(opts, state) do
    Keyword.merge(
      state.resubscribe_opts,
      Keyword.take(opts, [:credentials, :environment, :limiter, :plug, :req_adapter])
    )
  end

  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn pid -> if Process.alive?(pid), do: send(pid, message) end)
  end

  # Unique per feed. The venue disconnects an older connection presenting the same id.
  defp generate_session_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
