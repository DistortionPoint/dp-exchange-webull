defmodule DpExchange.Webull.Auth do
  @moduledoc """
  Signs a request with credentials the **host** has already obtained. Internal.

  > #### This package does not handle authentication {: .error}
  >
  > It signs. The host implements authentication, holds the credentials, and decides which
  > kind to use. This module is handed the result and turns it into headers — it never
  > obtains a credential, never stores one, never refreshes one, and never reads one from
  > the environment.

  ## Webull's scheme

  Every authenticated request carries:

      x-app-key:              <app key>
      x-timestamp:            <ISO 8601 UTC, second precision, "…Z">
      x-signature:            base64(HMAC-SHA1(app_secret <> "&", encoded_str))
      x-signature-algorithm:  HMAC-SHA1
      x-signature-version:    1.0
      x-signature-nonce:      <unique random string>
      x-version:              v2
      host:                   <api hostname, no scheme>
      x-access-token:         <token>   # only when the account has 2FA enabled

  ## The signature, step by step

  1. Collect the signing inputs: every query parameter, plus exactly six header pairs —
     `host`, `x-app-key`, `x-signature-algorithm`, `x-signature-nonce`,
     `x-signature-version`, `x-timestamp`. **`x-signature` and `x-version` deliberately do
     not participate.**
  2. Sort by name ascending and join as `name=value&name=value&…` → `str1`.
  3. If there is a body, uppercase-hex `MD5(body)` → `str2`. With no body, omit it entirely
     — not an MD5 of the empty string, which is a different value and a different
     signature.
  4. `str3 = path & str1`, or `path & str1 & str2` when a body is present.
  5. Percent-encode `str3` with **no safe characters**, so `/` becomes `%2F` and `:`
     becomes `%3A`.
  6. The HMAC key is `app_secret <> "&"` — the trailing ampersand is part of the key, not a
     separator. Sign with SHA-1 and base64 the result.

  **The host participates in the signature**, which is what stops a captured signature
  being replayed against a different environment. It is also why moving between production
  and the UAT host changes the signature rather than just the URL.

  ## Verified against the venue's own worked example

  Webull publishes an example whose expected output is `kvlS6opdZDhEBo5jq40nHYXaLvM=`. The
  test suite runs that example end to end and asserts the match, which is the only way to
  know the six steps above were read the same way the venue meant them.
  """

  @typedoc "Credentials the host obtained. Signed with, and not kept."
  @type credentials :: %{
          required(:app_key) => String.t(),
          required(:app_secret) => String.t(),
          optional(:access_token) => String.t() | nil
        }

  @typedoc "Everything the signature covers."
  @type request :: %{
          required(:path) => String.t(),
          required(:query_params) => %{optional(String.t()) => String.t()},
          required(:body) => String.t(),
          required(:host) => String.t(),
          required(:timestamp) => String.t(),
          required(:nonce) => String.t()
        }

  @doc """
  The full header set for a signed request.

  `host` is the API hostname **without a scheme**. It participates in signing, so a caller
  must pass the host it will actually reach.

  Returns `{:error, {:missing_credentials, :webull}}` rather than signing with a partial
  credential — a request signed with an absent secret fails at the venue with an error
  about signatures, which sends the reader looking in the wrong place.
  """
  @spec headers(request(), credentials()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def headers(request, credentials)

  def headers(%{} = request, %{app_key: app_key, app_secret: app_secret} = credentials)
      when is_binary(app_key) and is_binary(app_secret) do
    %{
      path: path,
      query_params: query_params,
      body: body,
      host: host,
      timestamp: timestamp,
      nonce: nonce
    } = request

    signature =
      signature(app_key, app_secret, path, query_params, body, host, timestamp, nonce)

    base = [
      {"x-app-key", app_key},
      {"x-timestamp", timestamp},
      {"x-signature", signature},
      {"x-signature-algorithm", "HMAC-SHA1"},
      {"x-signature-version", "1.0"},
      {"x-signature-nonce", nonce},
      {"x-version", "v2"},
      {"host", host}
    ]

    {:ok, with_access_token(base, Map.get(credentials, :access_token))}
  end

  def headers(_request, _credentials), do: {:error, {:missing_credentials, :webull}}

  @doc """
  The raw signature value.

  Exposed so the venue's published worked example can be verified directly — a signature
  scheme with six ordering-sensitive steps is not something to assume was read correctly.
  """
  @spec signature(
          String.t(),
          String.t(),
          String.t(),
          %{optional(String.t()) => String.t()},
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: String.t()
  def signature(app_key, app_secret, path, query_params, body, host, timestamp, nonce) do
    signing_headers = %{
      "host" => host,
      "x-app-key" => app_key,
      "x-signature-algorithm" => "HMAC-SHA1",
      "x-signature-nonce" => nonce,
      "x-signature-version" => "1.0",
      "x-timestamp" => timestamp
    }

    str1 =
      query_params
      |> Map.merge(signing_headers)
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map_join("&", fn {name, value} -> name <> "=" <> value end)

    str3 =
      case body do
        "" -> path <> "&" <> str1
        present -> path <> "&" <> str1 <> "&" <> uppercase_md5(present)
      end

    :hmac
    |> :crypto.mac(:sha, app_secret <> "&", URI.encode(str3, &unreserved?/1))
    |> Base.encode64()
  end

  @doc "A fresh per-request nonce — 32 random hex characters."
  @spec nonce() :: String.t()
  def nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc """
  The current time in the venue's required form: `YYYY-MM-DDThh:mm:ssZ`.

  Second precision with no fractional part. A fractional second changes the string, and
  the string is signed.
  """
  @spec timestamp(DateTime.t()) :: String.t()
  def timestamp(now \\ DateTime.utc_now()) do
    now
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:extended)
    |> String.replace(~r/\+00:00$/, "Z")
  end

  defp with_access_token(headers, token) when is_binary(token) and token != "",
    do: [{"x-access-token", token} | headers]

  defp with_access_token(headers, _absent), do: headers

  defp uppercase_md5(body), do: :md5 |> :crypto.hash(body) |> Base.encode16(case: :upper)

  # `URI.encode/2` keeps a character when this returns true. Webull's reference
  # implementation is Python's `urllib.parse.quote` with **no safe characters**, so `/`
  # and `:` are encoded too — the venue's own worked example shows `%2F` and `%3A`, which
  # is how this was confirmed rather than assumed.
  defp unreserved?(char) do
    char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?_, ?., ?~]
  end
end
