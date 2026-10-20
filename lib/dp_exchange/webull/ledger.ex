defmodule DpExchange.Webull.Ledger do
  @moduledoc """
  What `DpExchange.Webull.Feed` was asked to do, kept in a process that outlives it. Internal.

  ## Why this exists

  `Feed` is one named process holding every consumer's symbols, subscribers and the replay
  options (credentials included) in its state. A crash restarted it from its static start
  options: the wanted set empty, every subscriber forgotten, `coverage/1` reading `%{}` and the
  consumers told nothing. The sockets it had opened died with it (they are linked), so the
  stream was gone as well, silently.

  The ledger is started before the feed and is not restarted with it. The feed writes a snapshot
  of its **durable intent** here after every change it accepted (never one it refused or undid),
  and a restarted feed reads it back in `handle_continue/2`, re-monitors its subscribers, plans
  its shards again and tells each subscriber what happened.

  One snapshot, replaced whole, rather than a log: the feed knows its full intent each time, so
  a ledger that was itself restarted empty heals on the next accepted change instead of holding
  a half-applied history.

  The snapshot holds the credentials only inside `DpExchange.Webull.Credentials`, whose
  `Inspect` redacts them, so this process's state prints no secret in a crash report.
  """

  use Agent

  @typedoc "The feed's durable intent."
  @type intent :: %{
          wanted: [String.t()],
          subscribers: [pid() | atom()],
          notice_subscribers: [pid() | atom()],
          resubscribe_opts: keyword()
        }

  @doc "Starts the ledger under the registered `:name`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts), do: Agent.start_link(fn -> nil end, name: Keyword.fetch!(opts, :name))

  @doc """
  Replaces the snapshot. `:error` when the ledger is not running or does not answer, so the
  caller keeps its own copy and tries again at its next accepted change.
  """
  @spec put(GenServer.server(), intent()) :: :ok | :error
  def put(ledger, intent) do
    Agent.update(ledger, fn _previous -> intent end)
  catch
    :exit, _reason -> :error
  end

  @doc "The snapshot, or `:none` when nothing was written or the ledger is not running."
  @spec fetch(GenServer.server()) :: {:ok, intent()} | :none
  def fetch(ledger) do
    case Agent.get(ledger, & &1) do
      nil -> :none
      intent -> {:ok, intent}
    end
  catch
    :exit, _reason -> :none
  end
end
