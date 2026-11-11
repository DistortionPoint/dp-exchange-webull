defmodule DpExchange.Webull.DeclaredOptionsTest do
  @moduledoc """
  `start_options/0` and `call_options/1` (DistortionPoint/dp-exchange-core#43): the keys the
  facade and the fake say they accept are the keys the checks accept.

  The declaration and the check read one table, so these tests pin the seams between them:
  the start list is the one `check_start/1` refuses against, every declared key passes the
  matching `check/3` (with a `nil` value, which is still a key), the keys `:subscriber` and
  `:channels` that a consumer was refused at start are not declared, and an unknown name is an
  error rather than `{:ok, []}`. No call is made to the venue.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Webull
  alias DpExchange.Webull.{Fake, Options, Rest}

  @probe :dp_contract_unknown_option

  @facade_names Webull.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

  defp answers(module), do: for(name <- @facade_names, do: {name, module.call_options(name)})

  describe "start_options/0" do
    test "is the list check_start/1 refuses against, on the facade and the fake" do
      for module <- [Webull, Fake] do
        keys = module.start_options()

        assert keys == Options.start_keys()
        assert keys == Enum.uniq(keys)
        assert Enum.all?(keys, &is_atom/1)
        refute @probe in keys
      end
    end

    test "every declared key passes check_start/1, a nil value included" do
      for key <- Webull.start_options() do
        assert Options.check_start([{key, nil}]) == :ok, "start key #{inspect(key)} refused"
      end
    end

    test "a key outside the list is refused at start" do
      assert Options.check_start([{@probe, nil}]) == {:error, {:unknown_option, @probe}}
      assert Fake.start_link([{@probe, 1}]) == {:error, {:unknown_option, @probe}}
    end

    test "the keys a consumer was refused at start are not declared, and are refused" do
      for key <- [:subscriber, :channels] do
        refute key in Webull.start_options()
        refute key in Fake.start_options()
        assert Options.check_start([{key, nil}]) == {:error, {:unknown_option, key}}
      end
    end

    test "Keyword.take/2 over the list leaves a start the check accepts" do
      shared = [name: :x, subscriber: self(), channels: [:a], environment: :uat]
      taken = Keyword.take(shared, Webull.start_options())

      assert Keyword.keys(taken) == [:name, :environment]
      assert Options.check_start(taken) == :ok
    end
  end

  describe "call_options/1 on the facade" do
    test "every public function answers {:ok, unique atoms} or {:error, :not_supported}" do
      for {name, answer} <- answers(Webull) do
        case answer do
          {:ok, keys} ->
            assert Enum.all?(keys, &is_atom/1), "#{name}: #{inspect(keys)}"
            assert keys == Enum.uniq(keys), "#{name} declares a duplicate"

          other ->
            assert other == {:error, :not_supported}, "#{name}: #{inspect(other)}"
        end
      end
    end

    test "an inactive callback is not_supported, whatever it is" do
      for {name, _arity} <- Webull.venue_does_not_serve() do
        assert Webull.call_options(name) == {:error, :not_supported}
      end

      assert Webull.call_options(:get_market_overview) == {:error, :not_supported}
    end

    test "every declared key passes the matching check, nil value included" do
      for {name, {:ok, keys}} <- answers(Webull), Map.has_key?(own_table(), name) do
        for key <- keys do
          assert check_with_extras(name, key) == :ok,
                 "#{name} declares #{inspect(key)} but its check refuses it"
        end
      end
    end

    test "a key that is not declared is refused by the matching check" do
      for {name, {:ok, keys}} <- answers(Webull), Map.has_key?(own_table(), name) do
        refute @probe in keys
        assert Options.check(name, [{@probe, nil}]) == {:error, {:unknown_option, @probe}}
      end
    end

    test "the keys are the transport keys, :name, the function's own keys and extras" do
      {:ok, keys} = Webull.call_options(:get_price)
      assert :category in keys
      assert :credentials in keys
      assert :plug in keys
      refute :base_url in keys

      {:ok, once} = Webull.call_options(:place_order)
      assert :account_id in once
      refute :retry_attempts in once
      refute :retry_delay in once

      {:ok, oauth} = Webull.call_options(:oauth_token)
      refute :credentials in oauth
      assert :oauth_url in oauth
    end

    test "a call that sends no request declares no HTTP key" do
      {:ok, keys} = Webull.call_options(:get_fees)
      assert Enum.sort(keys) == [:credentials]

      {:ok, keys} = Webull.call_options(:streaming?)
      assert Enum.sort(keys) == [:credentials, :environment]

      {:ok, keys} = Webull.call_options(:coverage)
      refute :timeout in keys
      assert :feed in keys
    end

    test "functions that take no opts answer {:ok, []}" do
      for name <- [:provider_name, :runtime_id, :asset_classes, :capabilities, :start_options] do
        assert Webull.call_options(name) == {:ok, []}
      end

      assert Webull.call_options(:call_options) == {:ok, []}
      assert Webull.call_options(:venue_does_not_serve) == {:ok, []}
    end

    test "child_spec and start_link answer start_options/0" do
      assert Webull.call_options(:child_spec) == {:ok, Webull.start_options()}
      assert Webull.call_options(:start_link) == {:ok, Webull.start_options()}
    end

    test "get_fundamental and get_screener answer the union over every kind and name" do
      {:ok, fundamental} = Webull.call_options(:get_fundamental)

      for kind <- Rest.fundamental_kinds() do
        {:ok, kind_keys} = Rest.fundamental_option_keys(kind)
        assert kind_keys -- fundamental == [], "#{kind} has a key the union lacks"
      end

      {:ok, screener} = Webull.call_options(:get_screener)

      for name <- Rest.screeners() do
        {:ok, name_keys} = Rest.screener_option_keys(name)
        assert name_keys -- screener == [], "#{name} has a key the union lacks"
      end
    end

    test "an unknown name or a non-atom is unknown_function, never {:ok, []}" do
      assert Webull.call_options(:dp_contract_no_such_function) ==
               {:error, {:unknown_function, :dp_contract_no_such_function}}

      for bad <- ["get_price", 1, 1.5, {:get_price, 2}, %{}, [:get_price]] do
        assert Webull.call_options(bad) == {:error, {:unknown_function, bad}}
      end
    end
  end

  describe "the fake" do
    test "declares the same keys for every function, and the same refusals" do
      assert answers(Fake) == answers(Webull)
    end

    test "accepts every key the facade declares for an active endpoint" do
      for {name, {:ok, facade_keys}} <- answers(Webull) do
        assert {:ok, fake_keys} = Fake.call_options(name)
        assert facade_keys -- fake_keys == [], "#{name}: the fake lacks a facade key"
      end
    end

    test "an unknown name or a non-atom is unknown_function" do
      assert Fake.call_options(:dp_contract_no_such_function) ==
               {:error, {:unknown_function, :dp_contract_no_such_function}}

      assert Fake.call_options("get_price") == {:error, {:unknown_function, "get_price"}}
    end

    test "start_options matches the facade" do
      assert Fake.start_options() == Webull.start_options()
    end
  end

  # The functions that have a row in the options table.
  defp own_table do
    for {name, {:ok, _keys}} <- answers(Webull),
        match?(:ok, safe_own_keys(name)),
        into: %{},
        do: {name, true}
  end

  defp safe_own_keys(name) do
    Options.own_keys(name)
    :ok
  rescue
    KeyError -> :error
  end

  # `get_fundamental` and `get_screener` take part of their keys from the kind or name, so
  # each declared key is checked against the kind or name that reads it.
  defp check_with_extras(:get_fundamental, key) do
    kinds = Rest.fundamental_kinds()

    if Enum.any?(kinds, &extra_passes?(:get_fundamental, &1, key, :fundamental)),
      do: :ok,
      else: {:error, {:unknown_option, key}}
  end

  defp check_with_extras(:get_screener, key) do
    names = Rest.screeners()

    if Enum.any?(names, &extra_passes?(:get_screener, &1, key, :screener)),
      do: :ok,
      else: {:error, {:unknown_option, key}}
  end

  defp check_with_extras(name, key), do: Options.check(name, [{key, nil}])

  defp extra_passes?(function, argument, key, :fundamental) do
    {:ok, extra} = Rest.fundamental_option_keys(argument)
    Options.check(function, [{key, nil}], extra) == :ok
  end

  defp extra_passes?(function, argument, key, :screener) do
    {:ok, extra} = Rest.screener_option_keys(argument)
    Options.check(function, [{key, nil}], extra) == :ok
  end
end
