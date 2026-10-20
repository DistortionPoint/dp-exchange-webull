defmodule DpExchange.Webull.ProcessProbe do
  @moduledoc """
  The `:process_probe` of Core's conformance group 51: starts the long-lived processes of this
  package that hold credentials, with no network, and answers their pids.

  Group 51 hands in a credentials map with one canary under every secret key name and then asks
  each pid for `:sys.get_status/2`, which prints the state a crash report would print.

    * the `Feed`, started with the canary credentials and a pre-connected shard injected;
    * its `Ledger`, written with the feed's own replay options (the thing it holds);
    * a shard `Socket`, connected to a loopback server in this process tree that completes the
      WebSocket upgrade and then says nothing, with the canary as its App Key. The socket keeps
      the key inside `DpExchange.Webull.Credentials` and takes it out only to build the `CONNECT`.

  Nothing leaves the machine. The pids are stopped by the group; the loopback server gives up
  after a minute on its own.
  """

  alias DpExchange.Webull.{Feed, Ledger, Socket}

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @doc "Starts the feed, ledger and socket from a credentials map; `{:ok, [pid]}`."
  @spec start(map()) :: {:ok, [pid()]}
  def start(credentials) do
    unique = System.unique_integer([:positive])
    {:ok, socket} = start_socket(Map.get(credentials, :app_key, "k"), unique)

    {:ok, ledger} = Ledger.start_link(name: :"probe_ledger_#{unique}")

    shard = %{
      session_id: "probe-#{unique}",
      socket: socket,
      connected?: true,
      symbols: [],
      reply_to: nil
    }

    {:ok, feed} =
      Feed.start_link(
        name: :"probe_feed_#{unique}",
        ledger: :"probe_ledger_#{unique}",
        credentials: credentials,
        shards: %{0 => shard}
      )

    :ok =
      Ledger.put(ledger, %{
        wanted: [],
        subscribers: [],
        notice_subscribers: [],
        resubscribe_opts: :sys.get_state(feed).resubscribe_opts
      })

    {:ok, [feed, ledger, socket]}
  end

  defp start_socket(app_key, unique) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn(fn -> upgrade_then_wait(listen) end)

    Socket.start_link(
      url: "ws://127.0.0.1:#{port}/mqtt",
      subscriber: self(),
      session_id: "probe-socket-#{unique}",
      app_key: app_key
    )
  end

  defp upgrade_then_wait(listen) do
    {:ok, client} = :gen_tcp.accept(listen, 20_000)
    {:ok, request} = read_headers(client, "")

    :ok =
      :gen_tcp.send(
        client,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )

    Process.sleep(60_000)
  end

  defp read_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 20_000) do
        {:ok, data} -> read_headers(socket, acc <> data)
        {:error, _reason} = error -> error
      end
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end
