defmodule BonsaiServing.Latency do
  @moduledoc """
  Serving latency, read from the engine's own per-request line rather than timed from outside.

  The engine writes one line per finished request:

      req#14 done | openai-chat | stop token | prompt 27 | output 181 | cache 27 (100.0%, shared
      prefix) | TTFT 78.7 ms | total 1.4s | queue 45.9 ms | prefill 0.0 tok/s | decode 140.3 tok/s |
      dflash2 accepted 109/355 (30.7%)

  That line is the measurement: it separates queue, prefill, time-to-first-token and decode, and it
  reports how much of the prompt came from the shared-prefix cache. A client-side timer cannot see
  any of that split, so this module parses the line and leaves the timing to the engine.

  `measure/1` sends the requests and returns the lines they produced, with the request count taken
  before the run so only this run's lines are read.
  """
  alias BonsaiServing.{Config, Unit, Witness}

  @done ~r/req#(?<req>\d+) done \| (?<kind>[^|]+)\| (?<finish>[^|]+)\| prompt (?<prompt>[\d,]+) \| output (?<output>[\d,]+) \| cache (?<cache>[\d,]+) \((?<cache_pct>[\d.]+)%(?<cache_note>[^)]*)\) \| TTFT (?<ttft>[\d.]+)\s*(?<ttft_unit>ms|s) \| total (?<total>[\d.]+)\s*(?<total_unit>ms|s) \| queue (?<queue>[\d.]+)\s*(?<queue_unit>ms|s) \| prefill (?<prefill>[\d.]+)(?<prefill_scale>[kM]?) \s*(?<prefill_unit>[\w\/]+) \| decode (?<decode>[\d.]+)(?<decode_scale>[kM]?) \s*(?<decode_unit>[\w\/]+)(?: \| dflash2 accepted (?<spec_accepted>\d+)\/(?<spec_drafted>\d+) \((?<spec_pct>[\d.]+)%\))?/

  @doc "Pure: one `req#N done` line to a map, or `{:error, {:unparsed_done_line, line}}`."
  def parse_done(line) do
    case Regex.named_captures(@done, line) do
      nil ->
        {:error, {:unparsed_done_line, line}}

      c ->
        {:ok,
         %{
           req: int(c["req"]),
           prompt_tokens: int(c["prompt"]),
           output_tokens: int(c["output"]),
           cache_tokens: int(c["cache"]),
           cache_pct: float(c["cache_pct"]),
           cache_note: c["cache_note"] |> String.trim_leading(",") |> String.trim(),
           ttft_ms: ms(c["ttft"], c["ttft_unit"]),
           total_ms: ms(c["total"], c["total_unit"]),
           queue_ms: ms(c["queue"], c["queue_unit"]),
           prefill_tps: scaled(c["prefill"], c["prefill_scale"]),
           decode_tps: scaled(c["decode"], c["decode_scale"]),
           spec_accepted: int(c["spec_accepted"]),
           spec_drafted: int(c["spec_drafted"]),
           spec_pct: float(c["spec_pct"]),
           finish: String.trim(c["finish"])
         }}
    end
  end

  @doc "Pure: every `req#N done` line in a list, parsed."
  def parse_dones(lines) do
    lines
    |> Enum.filter(&String.contains?(&1, " done |"))
    |> Enum.flat_map(fn line ->
      case parse_done(line) do
        {:ok, parsed} -> [parsed]
        {:error, _} -> []
      end
    end)
  end

  @doc "The highest request number a unit has logged, or 0."
  def last_req(unit \\ nil) do
    case Unit.journal(unit) do
      {:ok, lines} ->
        lines
        |> parse_dones()
        |> Enum.map(& &1.req)
        |> Enum.max(fn -> 0 end)

      {:error, _} ->
        0
    end
  end

  @doc """
  A prompt of roughly `words` words. The engine reports the true prompt-token count, so this only
  has to be long enough to prefill.
  """
  def prompt(words) do
    sentence = "The quick brown fox jumps over the lazy dog and keeps running through the field. "

    target = words * 6
    sentence |> String.duplicate(div(target, String.length(sentence)) + 1) |> String.slice(0, target)
  end

  @doc """
  Send `:repeats` requests with the same prompt and return the engine's lines for them.

  Options: `:words` (prompt size, default 16), `:repeats` (default 2), `:max_tokens` (default 32),
  `:prompt` (an explicit prompt, which is what a caller measuring a real workload passes), `:unit`
  and `:port` (which server to measure: the served unit by default, a scratch arm otherwise).
  """
  def measure(opts \\ []) do
    words = Keyword.get(opts, :words, 16)
    repeats = Keyword.get(opts, :repeats, 2)
    max_tokens = Keyword.get(opts, :max_tokens, 32)
    prompt = Keyword.get(opts, :prompt) || prompt(words)
    unit = Keyword.get(opts, :unit)
    port = Keyword.get(opts, :port, Config.port())

    before = last_req(unit)

    results =
      Enum.map(1..repeats, fn _ ->
        Witness.ask(prompt, max_tokens: max_tokens, port: port)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        # The log is written before the response is released, so the lines are there.
        case Unit.journal(unit) do
          {:ok, lines} ->
            fresh = lines |> parse_dones() |> Enum.filter(&(&1.req > before))
            {:ok, %{requests: fresh, prompt_words: words, repeats: repeats}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A table of the requests, one row each, plus the row that is the baseline: the first request of the
  run, which had nothing to reuse. A number without a baseline is not a measurement.
  """
  def table(requests) do
    header = ["req#", "prompt", "cache", "TTFT", "prefill", "decode", "spec decode"]
    rows =
      Enum.map(requests, fn r ->
        [
          to_string(r.req),
          to_string(r.prompt_tokens),
          "#{r.cache_tokens} (#{r.cache_pct}%#{if r.cache_note == "", do: "", else: " " <> r.cache_note})",
          ms_label(r.ttft_ms),
          "#{round(r.prefill_tps)} tok/s",
          "#{r.decode_tps} tok/s",
          if(r.spec_drafted > 0,
            do: "#{r.spec_accepted}/#{r.spec_drafted} (#{r.spec_pct}%)",
            else: "-"
          )
        ]
      end)

    widths =
      Enum.reduce([header | rows], List.duplicate(0, length(header)), fn row, acc ->
        row |> Enum.zip(acc) |> Enum.map(fn {cell, width} -> max(String.length(cell), width) end)
      end)

    pad = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end

    [pad.(header), String.duplicate("-", Enum.sum(widths) + 2 * (length(widths) - 1)) | Enum.map(rows, pad)]
  end

  defp ms_label(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)} s"
  defp ms_label(ms), do: "#{ms} ms"

  # Regex.named_captures returns "" for a group that did not participate, not nil, so both spellings
  # of "absent" are handled.
  defp int(nil), do: 0
  defp int(""), do: 0
  defp int(text), do: text |> String.replace(",", "") |> String.to_integer()

  defp scaled(nil, _), do: 0.0
  defp scaled("", _), do: 0.0
  defp scaled(text, ""), do: float(text)
  defp scaled(text, "k"), do: float(text) * 1000.0
  defp scaled(text, "M"), do: float(text) * 1_000_000.0

  defp float(nil), do: 0.0
  defp float(""), do: 0.0
  defp float(text), do: elem(Float.parse(text), 0)

  defp ms(nil, _), do: 0.0
  defp ms("", _), do: 0.0
  defp ms(value, "s"), do: Float.round(elem(Float.parse(value), 0) * 1000, 1)
  defp ms(value, _), do: elem(Float.parse(value), 0)
end
