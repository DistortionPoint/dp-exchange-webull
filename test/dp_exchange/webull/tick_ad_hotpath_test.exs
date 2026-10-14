defmodule DpExchange.Webull.TickADHotPathTest do
  @moduledoc """
  Hot-path retention: values lifted out of a large inbound frame or response into something a
  consumer keeps must not pin the buffer they were sliced from. Proven structurally, by the
  size of the binary each value references, never by timing.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice}
  alias DpExchange.Webull.{Socket, Subscription}

  @moduletag :capture_log

  # Far past the 64-byte refc threshold, so a slice of it is a view and not a heap copy.
  @padding String.duplicate("x", 8_192)
  @credentials %{app_key: "test-key-not-real", app_secret: "test-secret-not-real"}

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

    limiter = :"lim_ad_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DefaultRateLimiter.start_link(
        name: limiter,
        limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
      )

    {:ok, limiter: limiter}
  end

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>

  defp field(number, value) when is_binary(value),
    do: varint(bsl(number, 3) ||| 2) <> varint(byte_size(value)) <> value

  defp publish(topic, payload) do
    body = <<byte_size(topic)::16>> <> topic <> payload
    <<3::4, 0::4>> <> varint(byte_size(body)) <> body
  end

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

  describe "a reported drop owns the fields it carries" do
    test "an unreadable tick's symbol and price do not pin the frame they were read from" do
      basic = field(1, "BTCUSD") <> field(3, "1787936147000")

      # Field 15 is unknown to the schema and skipped; it only makes the frame large.
      payload =
        field(1, basic) <>
          field(2, "1787936147000") <>
          field(3, "not-a-number") <>
          field(4, "1") <> field(15, @padding)

      frame = publish("tick", payload)
      assert byte_size(frame) > 8_192

      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}, 5_000
      assert notice.details.symbol == "BTCUSD"
      assert notice.details.price == "not-a-number"

      for key <- [:symbol, :price, :volume, :time] do
        value = Map.fetch!(notice.details, key)
        assert :binary.referenced_byte_size(value) == byte_size(value), "#{key} pins its frame"
      end
    end

    test "an unreadable snapshot's symbol does not pin the frame either" do
      basic = field(1, "ETHUSD")
      payload = field(1, basic) <> field(3, "NaN") <> field(15, @padding)

      frame = publish("snapshot", payload)
      assert {:ok, _state} = Socket.handle_frame({:binary, frame}, state())

      assert_receive {:dp_exchange, :webull, %Notice{kind: :data_quality} = notice}, 5_000
      assert notice.details.symbol == "ETHUSD"
      assert :binary.referenced_byte_size(notice.details.symbol) == 6
      assert :binary.referenced_byte_size(notice.details.price) == 3
    end
  end

  describe "Subscription's INVALID_SESSION answer" do
    test "the session id it names does not pin the response body", %{limiter: limiter} do
      session = "3c4fdabd54097164fbd0f66d95743aae"

      body = %{
        "error_code" => "INVALID_SESSION",
        "message" => "Mqtt connection not exist for session:" <> session,
        "padding" => @padding
      }

      plug = fn conn -> Req.Test.json(%{conn | status: 417}, body) end

      assert {:error, {:invalid_session, ^session = id}} =
               Subscription.subscribe("session-1", ["BTC-USD"],
                 credentials: @credentials,
                 limiter: limiter,
                 plug: plug,
                 retry_attempts: 0
               )

      assert :binary.referenced_byte_size(id) == byte_size(id)
    end
  end
end
