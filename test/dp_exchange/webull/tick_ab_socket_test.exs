defmodule DpExchange.Webull.TickAbSocketTest do
  @moduledoc """
  Message orderings of `Socket` that a real node can produce and a happy-path test never
  does. Every test drives the callbacks directly with a hand-built state, so no timing
  decides an outcome.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull.Socket

  @moduletag :capture_log

  defp state,
    do: %{
      subscriber: self(),
      session_id: "s1",
      app_key: "k",
      buffer: <<>>,
      qos2_pending: MapSet.new(),
      connected?: false,
      ping: nil,
      last_heard_at: nil
    }

  defp queued_connects do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, &(&1 == :send_connect))
  end

  describe "a reconnect that happens before the first CONNECT was sent" do
    test "queues no second :send_connect, so the new connection sees exactly one CONNECT" do
      # Interleaving: connection 1 is established, `handle_connect/2` queues `:send_connect`,
      # and a close that was already in the mailbox is read first. The reconnect runs
      # `handle_connect/2` again before the first `:send_connect` was handled. Two queued
      # messages meant two CONNECTs on connection 2, and a second CONNECT makes the broker
      # close it.
      assert {:ok, first} = Socket.handle_connect(:conn, state())
      assert {:ok, second} = Socket.handle_connect(:conn, first)

      assert queued_connects() == 1

      # The one message that is queued sends the CONNECT, and only once.
      assert {:reply, {:binary, <<1::4, 0::4, _rest::binary>>}, sent} =
               Socket.handle_info(:send_connect, second)

      assert is_reference(sent.ping)
    end

    test "once the CONNECT was sent, the next connection queues its own" do
      assert {:ok, first} = Socket.handle_connect(:conn, state())
      assert {:reply, _connect, sent} = Socket.handle_info(:send_connect, first)

      # Consume the message `first` queued, then reconnect.
      assert_receive :send_connect, 5_000
      assert queued_connects() == 0

      assert {:ok, _next} = Socket.handle_connect(:conn, sent)
      assert queued_connects() == 1
    end
  end
end
