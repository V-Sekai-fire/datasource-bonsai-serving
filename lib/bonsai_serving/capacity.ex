defmodule BonsaiServing.Capacity do
  @moduledoc """
  How much context the cards can hold: stop the unit, run one probe process with `--kv-capacity auto`
  at the requested window and dtype, read the capacity line it resolves, then start the unit again.
  The unit is restored whatever the probe does -- a probe must never leave the box half served.
  """
  alias BonsaiServing.{Arm, Config, Devices, Log, Unit}

  @doc """
  Pure: the probe's capacity line to a map.

  `capacity | KV 1,048,576 tokens, rk8v4, auto | pages 16,384/16,384 | runtime 13.2 GiB | free 4.49 GiB`
  """
  def parse_line(line) do
    pattern =
      ~r/capacity \| KV (?<tokens>[\d,]+) tokens, (?<kv_dtype>\S+), (?<mode>\S+) \| pages (?<pages_used>[\d,]+)\/(?<pages_total>[\d,]+) \| runtime (?<runtime>[\d.]+) (?<runtime_unit>\w+) \| free (?<free>[\d.]+) (?<free_unit>\w+)/

    case Regex.named_captures(pattern, line) do
      nil ->
        {:error, {:unparsed_capacity_line, line}}

      caps ->
        {:ok,
         %{
           tokens: number(caps["tokens"]),
           kv_dtype: caps["kv_dtype"],
           mode: caps["mode"],
           pages_used: number(caps["pages_used"]),
           pages_total: number(caps["pages_total"]),
           runtime: to_float(caps["runtime"]),
           runtime_unit: caps["runtime_unit"],
           free: to_float(caps["free"]),
           free_unit: caps["free_unit"],
           line: line
         }}
    end
  end

  defp number(text), do: text |> String.replace(",", "") |> String.to_integer()
  defp to_float(text), do: text |> Float.parse() |> elem(0)

  @doc """
  Probe options: `:kv_dtype` (default "rk8v4"), `:max_context` (default 1_048_576),
  `:port` (default 8098).
  """
  def probe(opts \\ []) do
    kv_dtype = Keyword.get(opts, :kv_dtype, "rk8v4")
    max_context = Keyword.get(opts, :max_context, 1_048_576)
    port = Keyword.get(opts, :port, 8098)

    with {:ok, pins} <- Devices.resolve() do
      :ok = Unit.stop()
      probe_result = run_probe(pins, kv_dtype, max_context, port)
      restore_result = restore()
      combine(probe_result, restore_result)
    end
  end

  @doc "The probe's argument list: the served list with the three flags the probe overrides."
  def probe_args(kv_dtype, max_context, port) do
    Config.unit_args()
    |> Config.replace("--max-context", to_string(max_context))
    |> Config.replace("--kv-capacity", "auto")
    |> Config.replace("--kv-dtype", kv_dtype)
    |> Kernel.++(["--rope-yarn", "--port", to_string(port)])
  end

  defp run_probe(pins, kv_dtype, max_context, port) do
    cvd = "#{pins.primary},#{pins.secondary}"
    args = probe_args(kv_dtype, max_context, port)

    with {:ok, unit} <- Arm.start("capacity", cvd, args) do
      result =
        case Unit.await(unit, "capacity |", Unit.since_stamp(), 600_000) do
          {:ok, line} ->
            case parse_line(line) do
              {:ok, capacity} -> {:ok, capacity}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            tail =
              case BonsaiServing.Shell.run(["journalctl", "-u", unit, "-o", "cat", "--no-pager"]) do
                {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.take(-8)
                _ -> []
              end

            {:error, {reason, tail}}
        end

      Arm.stop(unit)
      result
    end
  end

  defp restore do
    case Unit.start_ready() do
      {:ok, line} -> {:ok, Log.first_line(line, "listening on") |> elem(0)}
      {:error, reason} -> {:error, {:unit_not_restarted, reason}}
    end
  end

  defp combine({:ok, capacity}, {:ok, _}) do
    {:ok, capacity}
  end

  # A failed restore outranks a good probe: the box must be left serving.
  defp combine(_probe, {:error, reason}), do: {:error, reason}
  defp combine({:error, reason}, _), do: {:error, reason}
end
