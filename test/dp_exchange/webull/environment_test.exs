defmodule DpExchange.Webull.EnvironmentTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Webull.Environment

  describe "the URLs" do
    test "production" do
      assert Environment.rest_url(:production) == "https://api.webull.com"
      assert Environment.host(:production) == "api.webull.com"
      assert Environment.streaming_url(:production) == "wss://data-api.webull.com:8883/mqtt"
    end

    test "UAT has REST" do
      assert Environment.rest_url(:uat) == "https://us-openapi-alb.uat.webullbroker.com"
      assert Environment.host(:uat) == "us-openapi-alb.uat.webullbroker.com"
    end

    test "UAT has NO streaming, and says so rather than falling back" do
      # `mqtt-uat.webullbroker.com` is NXDOMAIN — there is no UAT broker. A consumer
      # testing against UAT who received production prices would be reading real market
      # data while believing it was fake.
      assert Environment.streaming_url(:uat) == nil
      refute Environment.streaming?(:uat)
      assert Environment.streaming?(:production)
    end

    test "the host is separate from the URL because the host is SIGNED" do
      # Webull signs the hostname so a signature cannot be replayed against another
      # environment. The two must agree, so both are derived from one place.
      for environment <- Environment.known() do
        assert Environment.rest_url(environment) =~ Environment.host(environment)
        refute Environment.host(environment) =~ "https://"
      end
    end
  end

  describe "resolution" do
    test "defaults to production" do
      assert Environment.resolve([]) == :production
    end

    test "an explicit option wins" do
      assert Environment.resolve(environment: :uat) == :uat
    end

    test "Core.Config resolves it per process" do
      Config.put_override(:environment, :uat)

      assert Environment.resolve([]) == :uat
    end

    test "an explicit option beats the process-scoped setting" do
      Config.put_override(:environment, :uat)

      assert Environment.resolve(environment: :production) == :production
    end

    test "an unknown environment RAISES rather than defaulting to production" do
      assert_raise ArgumentError, ~r/unknown Webull environment :uatt/, fn ->
        Environment.resolve(environment: :uatt)
      end
    end

    test "the error says why it refuses" do
      error = assert_raise ArgumentError, fn -> Environment.resolve(environment: "uat") end

      assert Exception.message(error) =~ "real order to a real broker"
    end
  end

  describe "live?/1" do
    test "production moves real money, UAT does not" do
      assert Environment.live?(:production)
      refute Environment.live?(:uat)
    end

    test "every known environment answers both questions" do
      for environment <- Environment.known() do
        assert is_boolean(Environment.live?(environment))
        assert is_boolean(Environment.streaming?(environment))
      end
    end
  end
end
