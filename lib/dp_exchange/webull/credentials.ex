defmodule DpExchange.Webull.Credentials do
  @moduledoc """
  Wraps the `app_key`/`app_secret`/`access_token` triple so it can sit in a `GenServer`'s
  state without printing in full the moment that process crashes.

  ## The incident this closes

  `Feed` keeps `state.resubscribe_opts` for its entire lifetime — a replay after a
  reconnect or a rebalance needs credentials, and the venue restores nothing itself, so
  this package retains what it was handed at `start_link/1` rather than asking the host
  to resupply them on every reconnect. `Socket` keeps `app_key` the same way, for every
  signed CONNECT it builds. OTP's default crash report prints a `GenServer`'s state in
  full on termination, and a **plain map** field prints every key including
  `app_secret` — the HMAC-SHA1 signing key — in cleartext. Verified against a real crash
  of an equivalent process holding `%{app_key: "...", app_secret: "...", access_token:
  "..."}` as a bare field.

  A struct whose `Inspect` implementation is derived with `except:` naming every field
  closes this: `Kernel.inspect/1` — which both the crash-report formatter and a
  `FunctionClauseError`'s printed argument list go through — honours a struct's
  `Inspect` protocol even nested inside an otherwise-plain state map. Wrapping once, at
  the point credentials enter a long-lived process, and letting the struct itself flow
  into every downstream call keeps `Auth.headers/2` working unchanged — `%{app_key:
  app_key, app_secret: app_secret} = credentials` still binds the real strings inside
  the one function that has to sign with them, and that binding is never itself stored
  or logged.

  ## `Keyword.take/2` sees this key only when it was actually given

  `Feed.init/1`'s `resubscribe_opts` and `replayable/2`'s per-call opts both build a
  keyword list with `Keyword.take(opts, [:credentials, ...])`, which omits `:credentials`
  entirely when a caller supplied none. `wrap_opt/1` mirrors that: it touches the
  `:credentials` entry only if present, rather than defaulting a missing one to `nil` —
  `Keyword.update/4`'s own default-insertion behaviour would otherwise INSERT
  `credentials: nil` into a per-call opts list that never had one, and `replayable/2`'s
  `Keyword.merge/2` would then let that inserted `nil` overwrite the real, already-wrapped
  credentials sitting in `state.resubscribe_opts` — silently discarding them on every
  call that did not itself pass fresh ones.

  ## The wrap lives in `child_spec/1`, so bypassing it bypasses the redaction

  `child_spec/1` is where `wrap_opt/1` is applied, because a supervisor captures the
  `{module, :start_link, [opts]}` MFA before `start_link/1` or `init/1` ever runs — see
  `wrap_opt/1`'s own doc. A consumer who uses the supported `{DpExchange.X, credentials:
  ...}` child form gets the redaction for free.

  **A consumer who builds the child spec themselves does not**, and upgrading this package
  will not change that: their supervisor stores the raw map and OTP renders it on the next
  crash, with nothing from this package on that path to intervene. It is a real path with a
  real reason — a caller needing a delivery target other than the supervisor has to reach
  `start_link/1` directly — so `wrap/1` and `wrap_opt/1` are **public** for it. Reported by
  a consumer who went looking for their canary in supervisor state after upgrading and
  found it; the natural assumption, "upgraded, therefore redacted", is wrong there.

  The same applies to a host that *reshapes* a credential before handing it over — mapping
  its own key names into this venue's and returning a bare map re-introduces the leak
  downstream of anything this package can reach.
  """

  @derive {Inspect, except: [:app_key, :app_secret, :access_token]}
  defstruct [:app_key, :app_secret, :access_token]

  @type t :: %__MODULE__{
          app_key: String.t() | nil,
          app_secret: String.t() | nil,
          access_token: String.t() | nil
        }

  @doc """
  Wraps a raw credentials map for storage in process state.

  `nil` passes through unchanged. Any other map is struct-ified with `Kernel.struct/2`,
  which ignores keys the struct does not declare rather than raising — matching how
  `Auth.headers/2` already reads this map, by pattern-matching only the keys it needs.
  """
  @spec wrap(map() | nil) :: t() | nil
  def wrap(nil), do: nil
  def wrap(%__MODULE__{} = credentials), do: credentials
  def wrap(credentials) when is_map(credentials), do: struct(__MODULE__, credentials)

  @doc """
  Wraps the `:credentials` entry of a keyword list of options, IN PLACE, only when that
  key is actually present — see the moduledoc's "`Keyword.take/2` sees this key only
  when it was actually given" section for why an unconditional default would corrupt
  `replayable/2`'s merge.
  """
  @spec wrap_opt(keyword()) :: keyword()
  def wrap_opt(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} -> Keyword.put(opts, :credentials, wrap(credentials))
      :error -> opts
    end
  end
end
