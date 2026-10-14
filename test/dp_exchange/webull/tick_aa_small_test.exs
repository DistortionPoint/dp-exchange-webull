defmodule DpExchange.Webull.TickAASmallTest do
  @moduledoc """
  Lines the full suite never executed in `MqttPacket`, `QuoteProto`, `Socket` and
  `Subscription`: each test reaches a refusal or fallback the code's own comments describe.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice}
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Webull.{MqttPacket, QuoteProto, Socket, Subscription}

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)

    limiter = :"lim_aa_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  defp field(number, value) when is_binary(value),
    do: varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value

  defp basic(symbol), do: field(1, symbol) <> field(3, "1787936147000")

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

  defp publish(topic, payload) do
    body = <<byte_size(topic)::16>> <> topic <> payload
    <<3::4, 0::4>> <> varint(byte_size(body)) <> body
  end

  defp responding(body, status), do: fn conn -> Req.Test.json(%{conn | status: status}, body) end
  defp raw(body, status), do: fn conn -> Plug.Conn.resp(conn, status, body) end

  defp subscribe(plug, limiter) do
    Subscription.subscribe("session-1", ["BTC-USD"],
      credentials: @credentials,
      limiter: limiter,
      plug: plug,
      retry_attempts: 0
    )
  end

  describe "MqttPacket.decode/1" do
    test "a PUBLISH whose topic length runs past its body is unhandled, not delivered" do
      # The topic claims nine bytes and two follow. Reading on would take the payload's bytes
      # for the topic; the body is handed back whole as `:unhandled`.
      body = <<9::16, "ab">>
      packet = <<3::4, 0::4, byte_size(body)>> <> body

      assert {:ok, {:unhandled, 3, ^body}, ""} = MqttPacket.decode(packet)
    end
  end

  describe "QuoteProto" do
    test "a tick or a quote given something that is not a binary is :error" do
      assert QuoteProto.decode_tick(nil) == :error
      assert QuoteProto.decode_quote(:not_a_payload) == :error
    end

    test "a wire type the schema never uses ends the walk and keeps what was read" do
      # Wire type 3 (start-group) has no reader here: the walk stops rather than guessing
      # where the next field begins, and the fields before it survive.
      assert QuoteProto.decode_message(field(1, "kept") <> <<0x0B, 1, 2>>) == %{1 => "kept"}
    end

    test "a singular Basic sent twice reads the LAST occurrence, as proto3 says" do
      payload = field(1, basic("OLD")) <> field(1, basic("NEW")) <> field(3, "77845.79")

      assert {:ok, %{symbol: "NEW"}} = QuoteProto.decode_tick(payload)
    end

    test "a Basic sent twice and never as a message names no symbol" do
      # Field 1 as a varint twice is a list of integers; no binary among them is no Basic.
      assert QuoteProto.decode_tick(<<0x08, 5, 0x08, 6>> <> field(3, "1")) == :error
    end
  end

  describe "Socket" do
    test "a non-string :url is refused as insecure, before anything is dialled" do
      assert {:error, {:insecure_url, :webull}} =
               Socket.start_link(url: nil, subscriber: self(), session_id: "s", app_key: "k")
    end

    test "a message it does not know is ignored and leaves the state alone" do
      assert {:ok, state()} == Socket.handle_info(:something_unexpected, state())
    end

    test "a notice whose content is only whitespace and which reports no drops is info" do
      json = Jason.encode!(%{"content" => "   ", "drop" => 0})

      assert {:ok, _state} = Socket.handle_frame({:binary, publish("notice", json)}, state())

      assert_receive {:dp_exchange, :webull, %Notice{} = notice}, 5_000
      assert notice.message == nil
      assert notice.severity == :info
    end

    test "a notice with no words but a non-zero drop is still a warning" do
      json = Jason.encode!(%{"content" => " ", "drop" => "3"})

      assert {:ok, _state} = Socket.handle_frame({:binary, publish("notice", json)}, state())

      assert_receive {:dp_exchange, :webull, %Notice{} = notice}, 5_000
      assert notice.message == nil
      assert notice.severity == :warning
    end

    test "a tick that cannot be decoded at all is reported as undecodable" do
      assert {:ok, _state} = Socket.handle_frame({:binary, publish("tick", "")}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality, details: details}},
                     5_000

      assert details.dropped == {:tick, :undecodable}
    end

    test "a venue time of zero is no time, not 1970" do
      payload = field(1, basic("BTCUSD")) <> field(2, "0") <> field(3, "1")

      assert {:ok, _state} = Socket.handle_frame({:binary, publish("snapshot", payload)}, state())

      assert_receive {:dp_exchange, :webull, %Quote{} = quoted}, 5_000
      assert quoted.venue_time == nil
    end

    test "a ten-digit venue time is read as seconds" do
      payload = field(1, basic("BTCUSD")) <> field(2, "1787936147") <> field(3, "1")

      assert {:ok, _state} = Socket.handle_frame({:binary, publish("snapshot", payload)}, state())

      assert_receive {:dp_exchange, :webull, %Quote{} = quoted}, 5_000
      assert quoted.venue_time == DateTime.from_unix!(1_787_936_147)
    end
  end

  describe "Subscription.subscribe/3 answers" do
    test "a 4xx outside the named refusals is an exchange_error carrying the status",
         %{limiter: limiter} do
      assert {:error, {:exchange_error, :webull, message}} =
               subscribe(responding(%{"msg" => "gone"}, 404), limiter)

      assert message =~ "HTTP 404"
    end

    test "a 417 whose error code is not one it names keeps the status and body",
         %{limiter: limiter} do
      assert {:error, {:exchange_error, :webull, message}} =
               subscribe(responding(%{"error_code" => "SOMETHING_NEW"}, 417), limiter)

      assert message =~ "HTTP 417"
      assert message =~ "SOMETHING_NEW"
    end

    test "an INVALID_SESSION with no message at all still names the session as unknown",
         %{limiter: limiter} do
      assert {:error, {:invalid_session, nil}} =
               subscribe(responding(%{"error_code" => "INVALID_SESSION"}, 417), limiter)
    end

    test "an INVALID_SYMBOL naming no symbol is the opaque error, never zero rejected symbols",
         %{limiter: limiter} do
      for body <- [
            %{"error_code" => "INVALID_SYMBOL", "message" => "bad [ , ]"},
            %{"error_code" => "INVALID_SYMBOL"},
            %{"error_code" => "INVALID_SYMBOL", "message" => 42}
          ] do
        assert {:error, {:exchange_error, :webull, message}} =
                 subscribe(responding(body, 417), limiter)

        assert message =~ "HTTP 417"
      end
    end

    test "a short text refusal is carried whole", %{limiter: limiter} do
      assert {:error, {:refused, 403, "forbidden"}} = subscribe(raw("forbidden", 403), limiter)
    end

    test "a long refusal that is not valid UTF-8 is cut at the byte bound, with a marker",
         %{limiter: limiter} do
      body = <<0xFF>> <> String.duplicate("a", 3_000)

      assert {:error, {:refused, 403, carried}} = subscribe(raw(body, 403), limiter)

      assert carried ==
               binary_part(body, 0, 2_048) <> "... [truncated, #{byte_size(body)} bytes in all]"
    end
  end
end
