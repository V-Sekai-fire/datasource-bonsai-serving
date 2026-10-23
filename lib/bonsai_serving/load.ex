defmodule BonsaiServing.Load do
  @moduledoc """
  Three measurements of the served unit under the shapes of traffic an agent produces.

    * `retention/1`: does a growing agent conversation stay cached while a long session is
      resident and other callers talk in between? This is the case that went cold under the
      original cache catalog (`private 2`): 11-17 s TTFT on every 30-39k-token turn.
    * `blocking/1`: does a short request wait behind another caller's cold prefill? Without
      `--concurrent-prefill` it waited the whole prefill (14.5 s behind 40k tokens).
    * `throughput/1`: total and per-stream decode with k requests in flight at once.

  Retention and blocking read TTFT and cache from the engine's own request lines (`Latency`);
  throughput is wall clock over tokens, because a total across streams has no engine line.
  Every function returns `{:ok, result}` or `{:error, reason}`.
  """
  alias BonsaiServing.{Config, Latency, Unit, Witness}

  @sentence "The quick brown fox jumps over the lazy dog. "

  # Ten tokens per sentence, measured: 1,500 copies made a 15,041-token prompt.
  @doc "Pure: filler text of roughly `tokens` tokens."
  def filler(tokens), do: String.duplicate(@sentence, div(tokens, 10) + 1)

  @doc "Pure: a fresh conversation whose system prompt is `tokens` long and unique to `tag`."
  def conversation(tag, tokens) do
    [
      %{role: "system", content: tag <> " Notes: " <> filler(tokens)},
      %{role: "user", content: "Describe the fox briefly."}
    ]
  end

  @doc "Pure: the conversation after one turn, extended the way an agent extends it."
  def extend(messages, reply) do
    messages ++
      [%{role: "assistant", content: reply}, %{role: "user", content: "Continue. #{length(messages)}"}]
  end

  # ---------------------------------------------------------------- retention
  @doc """
  Options: `:big` (tokens in the resident session, default 180_000), `:agent` (default 32_000),
  `:rounds` (agent turns after the cold one, default 4), `:others` (callers between turns,
  default 3). Returns one labelled engine row per request, in send order.
  """
  def retention(opts \\ []) do
    big = Keyword.get(opts, :big, 180_000)
    agent = Keyword.get(opts, :agent, 32_000)
    rounds = Keyword.get(opts, :rounds, 4)
    others = Keyword.get(opts, :others, 3)
    tag = nonce()

    with {:ok, session} <- Witness.session() do
      stamp = Unit.since_stamp()

      steps =
        [{"big session cold", :big}, {"big session turn 2", :big}, {"agent cold", :agent}] ++
          Enum.flat_map(1..rounds, fn round ->
            Enum.map(1..others, fn i -> {"  other caller #{round}.#{i}", {:other, round, i}} end) ++
              [{"agent turn after #{others} others", :agent}]
          end) ++ [{"big session again", :big}, {"agent again", :agent}]

      state = %{big: conversation("big " <> tag, big), agent: conversation("agent " <> tag, agent)}

      result =
        Enum.reduce_while(steps, {:ok, state}, fn {_label, which}, {:ok, acc} ->
          case step(which, acc, tag, session) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, _} <- result,
           {:ok, lines} <- Unit.journal(nil, stamp) do
        rows = Latency.parse_dones(lines)
        labels = Enum.map(steps, &elem(&1, 0))

        if length(rows) == length(labels) do
          {:ok, Enum.zip(labels, rows)}
        else
          {:error, {:row_count, length(labels), length(rows)}}
        end
      end
    end
  end

  defp step({:other, round, i}, acc, tag, session) do
    messages = [%{role: "user", content: "Other caller #{round}.#{i} #{tag}: say hi."}]

    with {:ok, _} <- Witness.chat(messages, session ++ [max_tokens: 16]) do
      {:ok, acc}
    end
  end

  defp step(which, acc, _tag, session) do
    with {:ok, %{text: text}} <- Witness.chat(Map.fetch!(acc, which), session ++ [max_tokens: 200]) do
      {:ok, Map.update!(acc, which, &extend(&1, text))}
    end
  end

  # ---------------------------------------------------------------- blocking
  @doc """
  A long cold prompt from one caller, and a short request from another sent as soon as the engine
  logs that the long one started. Options: `:long` (tokens, default 40_000), `:repeats` (default 2).
  Returns `[%{long_ms, short_ms}]`, both client wall time, one per repeat.
  """
  def blocking(opts \\ []) do
    long = Keyword.get(opts, :long, 40_000)
    repeats = Keyword.get(opts, :repeats, 2)

    with {:ok, session} <- Witness.session(),
         {:ok, _} <- Witness.chat([%{role: "user", content: "warm up"}], session ++ [max_tokens: 4]) do
      Enum.reduce_while(1..repeats, {:ok, []}, fn _, {:ok, acc} ->
        case blocking_once(long, session) do
          {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp blocking_once(long, session) do
    tag = nonce()
    stamp = Unit.since_stamp()
    long_task = Task.async(fn -> Witness.chat(conversation(tag, long), session ++ [max_tokens: 16]) end)

    # The engine's own "started" line is the event: the short request goes in once the long one
    # is admitted, so it lands mid-prefill without a sleep standing in for "probably started".
    # The needle names this request's shape (a system + user pair, 16 tokens out); the warm-up and
    # the short request carry one message, so neither can satisfy it.
    with {:ok, _line} <- Unit.await(Config.unit(), "| 2 messages | max output 16", stamp, 120_000),
         {:ok, short} <-
           Witness.chat([%{role: "user", content: "#{tag} Say hi."}], session ++ [max_tokens: 16]),
         {:ok, long_reply} <- Task.await(long_task, :infinity) do
      {:ok, %{long_ms: long_reply.wall_ms, short_ms: short.wall_ms}}
    end
  end

  # ---------------------------------------------------------------- throughput
  @doc """
  For each k in `:streams` (default [1, 2, 3]), send k different prompts at once, `:repeats` times
  (default 3), each asking for `:max_tokens` (default 600). Returns the median total and per-stream
  tok/s per k.
  """
  def throughput(opts \\ []) do
    streams = Keyword.get(opts, :streams, [1, 2, 3])
    repeats = Keyword.get(opts, :repeats, 3)
    max_tokens = Keyword.get(opts, :max_tokens, 600)

    with {:ok, session} <- Witness.session(),
         {:ok, _} <- Witness.chat(prompt(0), session ++ [max_tokens: 32]) do
      Enum.reduce_while(streams, {:ok, []}, fn k, {:ok, acc} ->
        case wave(k, repeats, max_tokens, session) do
          {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @topics [
    "client-side prediction and server reconciliation in multiplayer FPS games",
    "how a B-tree index works in a database and why it suits disks",
    "TCP congestion control, covering slow start and AIMD",
    "how a garbage collector finds live objects",
    "how a CPU branch predictor works",
    "how DNS resolves a name"
  ]

  defp prompt(i) do
    topic = Enum.at(@topics, rem(i, length(@topics)))
    [%{role: "user", content: "Write a detailed 400-word explanation of #{topic}."}]
  end

  defp wave(k, repeats, max_tokens, session) do
    runs =
      Enum.map(1..repeats, fn _ ->
        started = System.monotonic_time(:microsecond)

        replies =
          0..(k - 1)
          |> Task.async_stream(fn i -> Witness.chat(prompt(i), session ++ [max_tokens: max_tokens]) end,
            max_concurrency: k,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, reply} -> reply end)

        wall_s = (System.monotonic_time(:microsecond) - started) / 1_000_000
        {wall_s, replies}
      end)

    case Enum.find(Enum.flat_map(runs, &elem(&1, 1)), &match?({:error, _}, &1)) do
      nil ->
        rates =
          Enum.map(runs, fn {wall_s, replies} ->
            oks = Enum.map(replies, fn {:ok, r} -> r end)
            tokens = oks |> Enum.map(& &1.completion_tokens) |> Enum.sum()
            slowest_s = (oks |> Enum.map(& &1.wall_ms) |> Enum.max()) / 1000
            {tokens / wall_s, tokens / k / slowest_s}
          end)

        {:ok,
         %{
           streams: k,
           total_tps: median(Enum.map(rates, &elem(&1, 0))),
           per_stream_tps: median(Enum.map(rates, &elem(&1, 1)))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Pure: the median of a non-empty list of numbers."
  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp nonce, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
end
