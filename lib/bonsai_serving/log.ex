defmodule BonsaiServing.Log do
  @moduledoc "Pure log-line helpers, so the interesting logic is testable without a GPU or systemd."

  @doc """
  Split accumulated bytes on newlines and look for `needle` in the complete lines only. Returns
  `{:ok, line}` on the first match, otherwise `{:more, trailing_partial_line}` so the caller keeps
  only what it still has to match against.
  """
  def first_line(acc, needle) do
    parts = String.split(acc, "\n")
    {complete, [partial]} = Enum.split(parts, -1)

    case Enum.find(complete, &String.contains?(&1, needle)) do
      nil -> {:more, partial}
      line -> {:ok, line}
    end
  end

  @doc "The last line of a unit's log that contains `pattern`, or nil."
  def last_matching(lines, pattern) do
    lines |> Enum.filter(&String.contains?(&1, pattern)) |> List.last()
  end
end
