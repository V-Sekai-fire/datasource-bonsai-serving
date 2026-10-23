defmodule BlocklistTest do
  @moduledoc """
  The workspace blocklists error trapping in Elixir: no `try`, no `rescue`, no `catch`, no `throw`.
  Expected failures come back as `{:ok, value}` / `{:error, reason}`, and anything unexpected is left
  to crash. This test makes the rule a check instead of a habit.

  It matches the keyword as the first word of a line, which is every form the constructs take in real
  code (`try do`, `rescue e in X ->`, `catch :exit, x ->`, `throw(...)`), and it ignores comments so a
  note about the rule is not an offence.
  """
  use ExUnit.Case, async: true

  @offender ~r/^\s*(try|rescue|catch|throw)\b/

  test "the matcher sees a planted offender" do
    planted = """
    def call do
      try do
        :ok
      rescue
        _ -> :error
      end
    end
    """

    assert planted |> String.split("\n") |> Enum.any?(&Regex.match?(@offender, &1)),
           "the matcher must fire on a planted try/rescue, or this check is decoration"
  end

  test "a comment about the rule is not an offence" do
    refute Regex.match?(@offender, "  # no try or rescue here")
  end

  test "lib/ carries no error trapping" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(@offender, line) end)
        |> Enum.map(fn {line, number} -> "#{path}:#{number}: #{String.trim(line)}" end)
      end)

    assert offenders == [], "blocklisted construct(s) in lib/:\n" <> Enum.join(offenders, "\n")
  end
end
