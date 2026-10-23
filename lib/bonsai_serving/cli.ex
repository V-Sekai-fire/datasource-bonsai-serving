defmodule BonsaiServing.CLI do
  @moduledoc """
  Command line for the ops app. Every command prints a plain result and exits 0 on success, 1 on a
  tagged error -- no command raises for an expected failure.

      mix bonsai status
      mix bonsai devices
      mix bonsai witness [--expected SHA]
      mix bonsai capacity [--kv-dtype rk8v4] [--max-context 1048576]
      mix bonsai start | stop
  """
  alias BonsaiServing.{Capacity, Config, Devices, Unit, Witness}

  @switches [expected: :string, kv_dtype: :string, max_context: :integer, port: :integer, max_tokens: :integer]

  def main(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    code =
      cond do
        invalid != [] ->
          IO.puts("bad options: #{inspect(invalid)}")
          usage()
          1

        true ->
          dispatch(rest, Map.new(opts))
      end

    System.halt(code)
  end

  defp dispatch(["status"], _), do: status()
  defp dispatch(["devices"], _), do: devices()
  defp dispatch(["witness"], opts), do: witness(opts)
  defp dispatch(["capacity"], opts), do: capacity(opts)
  defp dispatch(["start"], _), do: start_unit()
  defp dispatch(["stop"], _), do: stop_unit()
  defp dispatch(_, _), do: usage()

  defp usage do
    IO.puts("""
    usage: mix bonsai <command>

      status                     unit state, the split and capacity lines, per-card memory
      devices                    the pinned UUIDs, checked against the cards present
      witness [--expected SHA]   one temperature-0 answer, hashed and compared
      capacity [--kv-dtype X]    stop the unit, probe the KV ceiling, start the unit again
               [--max-context N]
      start | stop               the unit
    """)

    1
  end

  # ---------------------------------------------------------------- commands
  defp status do
    with {:ok, state} <- Unit.status(),
         {:ok, lines} <- Unit.journal() do
      IO.puts("#{Config.unit()}: #{state}")

      for pattern <- ["device profile", "weights ready", "capacity |", "device 0 |", "device 1 |"],
          line = BonsaiServing.Log.last_matching(lines, pattern),
          line != nil do
        IO.puts(line)
      end

      cards()
      0
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp cards do
    case BonsaiServing.Shell.run(["nvidia-smi", "--query-gpu=index,name,memory.used", "--format=csv,noheader"]) do
      {:ok, out} -> IO.puts("--- cards\n" <> out)
      {:error, _} -> :ok
    end
  end

  defp devices do
    case Devices.resolve() do
      {:ok, pins} ->
        IO.puts("primary   #{pins.primary} = #{pins.cards.primary.name}")
        IO.puts("secondary #{pins.secondary} = #{pins.cards.secondary.name}")
        0

      {:error, reason} ->
        fail(reason)
    end
  end

  defp witness(opts) do
    expected = Map.get(opts, :expected, Config.witness_sha())

    case Witness.verify(expected: expected, max_tokens: Map.get(opts, :max_tokens, 200)) do
      {:ok, answer} ->
        IO.puts("sha256=#{answer.sha256} chars=#{answer.chars}")
        IO.puts(String.slice(answer.text, 0, 200))
        IO.puts("WITNESS: matches the expected answer")
        0

      {:error, {:mismatch, expected_sha, got, answer}} ->
        IO.puts("sha256=#{got} chars=#{answer.chars}")
        IO.puts(String.slice(answer.text, 0, 200))
        fail({:mismatch, expected_sha, got})

      {:error, reason} ->
        fail(reason)
    end
  end

  defp capacity(opts) do
    probe_opts =
      [kv_dtype: Map.get(opts, :kv_dtype, "rk8v4"), max_context: Map.get(opts, :max_context, 1_048_576)] ++
        case Map.get(opts, :port) do
          nil -> []
          port -> [port: port]
        end

    case Capacity.probe(probe_opts) do
      {:ok, capacity} ->
        IO.puts(capacity.line)
        IO.puts("tokens=#{capacity.tokens} pages=#{capacity.pages_used}/#{capacity.pages_total} free=#{capacity.free} #{capacity.free_unit}")
        0

      {:error, reason} ->
        fail(reason)
    end
  end

  defp start_unit do
    case Unit.start_ready() do
      {:ok, line} ->
        IO.puts(line)
        0

      {:error, reason} ->
        fail(reason)
    end
  end

  defp stop_unit do
    :ok = Unit.stop()

    case Unit.status() do
      {:ok, state} ->
        IO.puts("#{Config.unit()}: #{state}")
        0

      {:error, reason} ->
        fail(reason)
    end
  end

  defp fail(reason) do
    IO.puts("error: #{inspect(reason)}")
    1
  end
end
