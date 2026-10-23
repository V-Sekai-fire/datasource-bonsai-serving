defmodule BonsaiServing.Sweep do
  @moduledoc """
  One flag at a time, measured by the engine, with the served configuration as the first row.

  A variant cannot be tested on the served unit, because the unit's arguments are what the variant
  changes. So the unit is stopped once, each variant runs as a scratch arm on the same two cards
  (the `Arm` the capacity probe already uses), and the unit is started again at the end whatever
  happened.

  Every row is the engine's own line for the same prompt, so the only thing that differs between
  rows is the flag.
  """
  alias BonsaiServing.{Arm, Config, Devices, Latency, Unit}

  @doc """
  Variants as `{name, transform}`, where the transform rewrites the served argument list.

      mix bonsai sweep --words 4000 --repeats 2
  """
  def variants do
    [
      {:served, & &1},
      {:no_vision, &Enum.reject(&1, fn arg -> arg == "--vision" end)},
      {:draft3, &replace(&1, "--draft-tokens", "3")},
      {:draft8, &replace(&1, "--draft-tokens", "8")},
      {:kv_rk4v4_e8, &replace(&1, "--kv-dtype", "rk4v4-e8")},
      {:fast_prefill, &(&1 ++ ["--fast-prefill-kernel"])},
      {:prefill_cublas, &(&1 ++ ["--prefill-cublas"])},
      {:prefill_chunk4096, &Config.replace(&1, "--prefill-chunk", "4096")},
      {:graph_off, &(&1 ++ ["--no-cuda-graph"])},
      # Speculative decoding pays only when the drafts land: acceptance was 86.7% on one prompt and
      # 21.1% on another, and the decode rate moved with it. Without --spec the rate is lower but
      # does not depend on the content.
      {:no_spec, &remove_spec(&1)},
      {:draft2, &Config.replace(&1, "--draft-tokens", "2")}
    ]
  end

  @doc "Replace a flag's value, or append the flag when it is absent."
  defdelegate replace(args, flag, value), to: Config

  @doc "Drop the speculative flags with their values, which is how the engine runs without a draft."
  def remove_spec(args), do: args |> drop_flag("--spec") |> drop_flag("--draft-tokens")

  defp drop_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> args
      index -> args |> List.delete_at(index) |> List.delete_at(index)
    end
  end

  @doc """
  Measure the served configuration and then every variant.

  Options: `:words` (default 4000), `:repeats` (default 2), `:max_tokens` (default 64),
  `:arm_port` (default 8097), `:only` (a list of variant names, default all).
  """
  def run(opts \\ []) do
    words = Keyword.get(opts, :words, 4_000)
    repeats = Keyword.get(opts, :repeats, 2)
    max_tokens = Keyword.get(opts, :max_tokens, 64)
    port = Keyword.get(opts, :arm_port, 8097)
    prompt = Latency.prompt(words)
    only = Keyword.get(opts, :only)

    wanted =
      variants()
      |> Enum.filter(fn {name, _} -> is_nil(only) || name in only end)

    served =
      Enum.filter(wanted, fn {name, _} -> name == :served end)
      |> Enum.map(fn _ -> {:served, measure_served(prompt, repeats, max_tokens)} end)

    arms = Enum.reject(wanted, fn {name, _} -> name == :served end)

    case arms do
      [] ->
        {:ok, %{rows: served, restore: :ok}}

      _ ->
        # The arms need the cards, so the unit goes down once for the whole sweep and comes back
        # once, after every arm has run.
        :ok = Unit.stop()

        with {:ok, pins} <- Devices.resolve() do
          cvd = "#{pins.primary},#{pins.secondary}"

          rows =
            served ++
              Enum.map(arms, fn {name, transform} ->
                {name, measure_arm(name, transform, cvd, prompt, repeats, max_tokens, port)}
              end)

          restore =
            case Unit.start_ready() do
              {:ok, _line} -> :ok
              {:error, reason} -> {:error, {:unit_not_restarted, reason}}
            end

          {:ok, %{rows: rows, restore: restore}}
        end
    end
  end

  @doc """
  One line per variant: the cold request's time-to-first-token, the warm one's, and the warm
  decode rate, so the flag that helps and the flag that only helps after a cache hit are told apart.
  """
  def summary(rows) do
    header = ["variant", "prompt", "cache", "TTFT cold", "TTFT warm", "prefill", "decode", "spec"]

    body =
      Enum.map(rows, fn
        {name, {:ok, %{requests: []}}} ->
          [to_string(name), "-", "no request logged", "-", "-", "-", "-", "-"]

        {name, {:ok, %{requests: requests}}} ->
          cold = hd(requests)
          warm = List.last(requests)

          [
            to_string(name),
            to_string(warm.prompt_tokens),
            "#{warm.cache_tokens} (#{warm.cache_pct}%)",
            ms(cold.ttft_ms),
            ms(warm.ttft_ms),
            "#{round(warm.prefill_tps)} tok/s",
            "#{warm.decode_tps} tok/s",
            if(warm.spec_drafted > 0, do: "#{warm.spec_accepted}/#{warm.spec_drafted}", else: "-")
          ]

        {name, {:error, reason}} ->
          [to_string(name), "failed", inspect(reason), "-", "-", "-", "-", "-"]
      end)

    widths =
      Enum.reduce([header | body], List.duplicate(0, length(header)), fn row, acc ->
        row |> Enum.zip(acc) |> Enum.map(fn {cell, width} -> max(String.length(cell), width) end)
      end)

    pad = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end

    [pad.(header), String.duplicate("-", Enum.sum(widths) + 2 * (length(widths) - 1)) | Enum.map(body, pad)]
  end

  defp ms(value) when value >= 1000, do: "#{Float.round(value / 1000, 2)} s"
  defp ms(value), do: "#{round(value)} ms"

  defp measure_served(prompt, repeats, max_tokens) do
    Latency.measure(prompt: prompt, repeats: repeats, max_tokens: max_tokens)
  end

  defp measure_arm(name, transform, cvd, prompt, repeats, max_tokens, port) do
    args = transform.(Config.unit_args()) ++ ["--port", to_string(port)]

    with {:ok, unit} <- Arm.start("#{name}", cvd, args),
         {:ok, _line} <- Unit.await(unit, "listening on", Unit.since_stamp(), 600_000) do
      result = Latency.measure(prompt: prompt, repeats: repeats, max_tokens: max_tokens, unit: unit, port: port)
      Arm.stop(unit)
      result
    else
      {:error, reason} ->
        Arm.stop("ninfer-arm-#{name}")
        {:error, reason}
    end
  end
end
