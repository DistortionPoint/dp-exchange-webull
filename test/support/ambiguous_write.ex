defmodule DpExchange.Webull.AmbiguousWrite do
  @moduledoc """
  Test support for conformance group 42 (`ambiguous_place_order:`).

  Runs the REAL `Rest.place_order/3` against a Req plug that answers 503 on every attempt:
  the request has been sent, so the outcome is ambiguous and must come back as
  `{:error, {:order_unconfirmed, client_order_id, reason}}`. A request without an
  `:order_type` is refused before signing and must not.
  """

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Rest

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

  @doc """
  `Rest.place_order/3` under a 503 fault. `request` is the contract's base request.

  The contract's generic base is mapped to a request this venue's real path accepts (a
  crypto GTC limit order); only its `:client_order_id` and the presence of `:order_type`
  are taken from it, so group 42's pre-send case (no `:order_type`) stays pre-send.
  """
  @spec place(map()) :: term()
  def place(request) when is_map(request) do
    Config.put_override(:rate_limit_module, PermissiveLimiter)

    mapped =
      %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }
      |> put_client_order_id(Map.get(request, :client_order_id))
      |> drop_order_type(Map.has_key?(request, :order_type))

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, Jason.encode!(%{"msg" => "unavailable"}))
    end

    Rest.place_order(
      %{app_key: "key", app_secret: "secret"},
      mapped,
      plug: plug,
      account_id: "contract-account",
      retry_attempts: 3,
      retry_delay: 1
    )
  end

  defp put_client_order_id(mapped, id) when is_binary(id),
    do: Map.put(mapped, :client_order_id, id)

  defp put_client_order_id(mapped, _none), do: mapped

  defp drop_order_type(mapped, true), do: mapped
  defp drop_order_type(mapped, false), do: Map.delete(mapped, :order_type)
end
