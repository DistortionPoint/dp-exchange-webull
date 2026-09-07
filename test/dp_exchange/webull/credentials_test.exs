defmodule DpExchange.Webull.CredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DpExchange.Webull.Credentials

  @app_key "LEAK_PROOF_APP_KEY_abc123"
  @app_secret "LEAK_PROOF_APP_SECRET_def456"
  @access_token "LEAK_PROOF_ACCESS_TOKEN_ghi789"

  describe "wrap/1" do
    test "nil passes through unchanged" do
      assert Credentials.wrap(nil) == nil
    end

    test "a raw credentials map is struct-ified" do
      wrapped =
        Credentials.wrap(%{
          app_key: @app_key,
          app_secret: @app_secret,
          access_token: @access_token
        })

      assert %Credentials{
               app_key: @app_key,
               app_secret: @app_secret,
               access_token: @access_token
             } = wrapped
    end

    test "already-wrapped credentials pass through unchanged" do
      wrapped = Credentials.wrap(%{app_key: @app_key, app_secret: @app_secret})

      assert Credentials.wrap(wrapped) == wrapped
    end

    test "an unrelated extra key is ignored, matching how Auth.headers/2 already reads " <>
           "this map — pattern-matching only the keys it needs" do
      wrapped = Credentials.wrap(%{app_key: @app_key, app_secret: @app_secret, extra: "x"})

      assert wrapped.app_key == @app_key
      assert wrapped.app_secret == @app_secret
    end
  end

  describe "wrap_opt/1" do
    test "wraps the :credentials entry when present" do
      opts = [credentials: %{app_key: @app_key, app_secret: @app_secret}, environment: :prod]
      wrapped_opts = Credentials.wrap_opt(opts)

      assert %Credentials{app_key: @app_key, app_secret: @app_secret} =
               Keyword.get(wrapped_opts, :credentials)

      assert Keyword.get(wrapped_opts, :environment) == :prod
    end

    test "leaves the opts untouched when :credentials is absent — an unconditional " <>
           "default would insert `credentials: nil` and let replayable/2's Keyword.merge/2 " <>
           "silently discard already-wrapped credentials sitting in state.resubscribe_opts" do
      opts = [environment: :prod, limiter: :my_limiter]

      assert Credentials.wrap_opt(opts) == opts
      refute Keyword.has_key?(Credentials.wrap_opt(opts), :credentials)
    end
  end

  describe "Inspect redaction" do
    test "no secret field appears in the struct's own inspected output" do
      wrapped =
        Credentials.wrap(%{
          app_key: @app_key,
          app_secret: @app_secret,
          access_token: @access_token
        })

      rendered = inspect(wrapped)

      refute rendered =~ @app_key
      refute rendered =~ @app_secret
      refute rendered =~ @access_token
      assert rendered =~ "DpExchange.Webull.Credentials<...>"
    end

    test "the secret stays redacted nested inside a keyword list — the exact shape " <>
           "state.resubscribe_opts takes" do
      opts = [credentials: Credentials.wrap(%{app_secret: @app_secret}), environment: :prod]

      refute inspect(opts) =~ @app_secret
    end
  end

  describe "crash-report proof" do
    # Mirrors the exact state-construction idiom `Feed.init/1` (feed.ex) uses:
    # credentials wrapped via `Credentials.wrap_opt/1` and stored inside
    # `state.resubscribe_opts`, a keyword list that is itself a top-level field of the
    # GenServer's state. Before this fix, the equivalent state shape — a PLAIN map, not
    # this struct — printed `app_secret` and `access_token` in full on a crash of `Feed`;
    # this proves the wrapping mechanism it now relies on. `async: false`: a
    # `CaptureLog`-content assertion under `async: true` was already found
    # non-concurrency-safe once in this family.
    defmodule LeakyProbe do
      use GenServer

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @spec init(keyword()) :: {:ok, map()}
      def init(opts) do
        {:ok, %{resubscribe_opts: DpExchange.Webull.Credentials.wrap_opt(opts)}}
      end

      @spec boom(pid()) :: any()
      def boom(pid), do: GenServer.call(pid, :boom)

      @spec handle_call(:boom, GenServer.from(), map()) :: no_return()
      def handle_call(:boom, _from, _state), do: raise("simulated crash for leak-proof test")
    end

    test "a crash of a process holding wrapped credentials never prints the secrets" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, pid} =
            LeakyProbe.start_link(
              credentials: %{
                app_key: @app_key,
                app_secret: @app_secret,
                access_token: @access_token
              }
            )

          ref = Process.monitor(pid)

          try do
            LeakyProbe.boom(pid)
          catch
            :exit, _reason -> :ok
          end

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "simulated crash for leak-proof test"
      refute log =~ @app_key
      refute log =~ @app_secret
      refute log =~ @access_token
      assert log =~ "DpExchange.Webull.Credentials<...>"
    end
  end
end
