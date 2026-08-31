defmodule DpExchange.Webull.DocumentedPathsTest do
  @moduledoc """
  Every path this package calls must be one Webull currently documents.

  ## Why this test exists, and why it did not before

  Until the D6 migration, all five of this package's endpoints used an `/openapi/…` prefix
  that appears nowhere in the vendor's current documentation. They were inherited from the
  host adapter's reading of an older site, and **the entire suite passed the whole time**:
  no test asserted a path, so nothing distinguished a documented endpoint from a
  remembered one.

  That is the gap this closes. A path is the one thing in an HTTP call that cannot be
  verified by reading the response — a wrong path returns a plausible error, and a package
  that never asserts its paths cannot tell "the venue is down" from "we have been calling
  the wrong URL for a year".

  ## The migration this locks in

      /openapi/market-data/crypto/snapshot      ->  /market-data/crypto/snapshots/list
      /openapi/market-data/crypto/bars          ->  /market-data/crypto/bars/list
      /openapi/instrument/crypto/list           ->  /trading/instruments/crypto/profiles/list
      /openapi/market-data/streaming/subscribe  ->  /market-data/streaming/subscribe
      /openapi/market-data/streaming/unsubscribe -> /market-data/streaming/unsubscribe

  **The paths were not the whole of it**, which is worth recording because the coverage
  plan predicted otherwise ("no probe needed: every one has a documented replacement").
  True of the paths; false of the payloads. Three of the five also changed shape:

  - **snapshots** stamp rows `last_trade_time` / `quote_time`, neither of which the
    timestamp reader accepted — every quote would have failed `:missing_venue_timestamp`
  - **bars** renamed `symbol` to `symbols` and added a *required* `real_time_required`
  - **instruments** made `category` required and became paginated, so one call now returns
    a page rather than the catalogue

  A path-only rewrite would have compiled, passed, and been wrong in three places.
  """

  use ExUnit.Case, async: true

  @lib Path.join([__DIR__, "..", "..", "..", "lib"]) |> Path.expand()

  @documented [
    "/market-data/crypto/snapshots/list",
    "/market-data/crypto/bars/list",
    "/trading/instruments/crypto/profiles/list",
    "/market-data/streaming/subscribe",
    "/market-data/streaming/unsubscribe"
  ]

  defp source_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  # Documentation may legitimately name the old paths to explain the migration; code may
  # not use them. Strip heredocs and comments so this checks calls, not prose.
  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_heredoc?} ->
      cond do
        in_heredoc? and String.contains?(line, ~s(""")) -> {acc, false}
        in_heredoc? -> {acc, true}
        String.contains?(line, ~s(""")) -> {acc, true}
        true -> {[String.replace(line, ~r/#.*$/, "") | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp all_code, do: source_files() |> Enum.map_join("\n", &code_only(File.read!(&1)))

  test "no code path uses the undocumented /openapi prefix" do
    offenders =
      for path <- source_files(),
          code = code_only(File.read!(path)),
          String.contains?(code, "/openapi/") do
        Path.relative_to(path, @lib)
      end

    assert offenders == [],
           """
           These files still call the undocumented `/openapi/…` paths: #{inspect(offenders)}

           Every one has a documented replacement (D6). Migrating the path is not enough —
           check the parameters and the response shape too; three of the five changed.
           """
  end

  test "every documented path is actually called" do
    code = all_code()

    missing = Enum.reject(@documented, &String.contains?(code, &1))

    assert missing == [],
           """
           These documented paths are not called anywhere in code: #{inspect(missing)}

           This test's other half only proves the old paths are gone. This half proves the
           new ones arrived — without it, deleting a call would pass.
           """
  end

  test "the bars call sends the parameters the replacement requires" do
    code = all_code()

    # `symbols`, not `symbol`, and `real_time_required` is required where the old path had
    # no such parameter.
    assert code =~ ~s("symbols"), "bars/snapshots take `symbols`; `symbol` was the old name"
    assert code =~ ~s("real_time_required"), "required by /market-data/crypto/bars/list"
  end

  test "the instrument call sends the now-required category" do
    assert all_code() =~ ~s("category" => "US_CRYPTO")
  end

  test "stripping documentation does not strip the whole file" do
    assert all_code() =~ "defmodule"
  end
end
