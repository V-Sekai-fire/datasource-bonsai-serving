defmodule BonsaiServing.Unit do
  @moduledoc """
  Owns the `ninfer-serve` systemd unit. One process, so two callers cannot race a start against a
  stop, and every wait is driven by the unit's own log line rather than by a sleep.
  """
  use GenServer
  alias BonsaiServing.{Config, Shell}

  # ---------------------------------------------------------------- client
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Systemd's own answer: :active, :inactive, :activating, :failed, ..."
  def status, do: GenServer.call(__MODULE__, :status, 30_000)
  def start, do: GenServer.call(__MODULE__, :start, 60_000)
  def stop, do: GenServer.call(__MODULE__, :stop, 60_000)

  @doc "Start and wait for `listening on`. {:error, reason} if it never says it."
  def start_ready(timeout_ms \\ 180_000), do: GenServer.call(__MODULE__, {:start_ready, timeout_ms}, timeout_ms + 30_000)

  @doc "Block until the unit logs a line containing `needle`."
  def wait_for_line(needle, timeout_ms \\ 300_000),
    do: GenServer.call(__MODULE__, {:wait_for_line, needle, timeout_ms}, timeout_ms + 30_000)

  @doc "A unit's log as a list of lines (the served unit by default)."
  def journal(unit \\ nil), do: GenServer.call(__MODULE__, {:journal, unit}, 30_000)

  # ---------------------------------------------------------------- server
  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:status, _from, state) do
    # `systemctl is-active` exits non-zero for every state but active; the word is the answer.
    result =
      case Shell.run(["systemctl", "is-active", Config.unit()]) do
        {:ok, word} -> {:ok, String.to_atom(word)}
        {:error, {:exit, _code, word}} when word != "" -> {:ok, String.to_atom(word)}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call(:start, _from, state) do
    {:reply, Shell.quietly(["sudo", "systemctl", "start", Config.unit()]), state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, Shell.quietly(["sudo", "systemctl", "stop", Config.unit()]), state}
  end

  def handle_call({:start_ready, timeout_ms}, _from, state) do
    # Stamp the window before the start, so a previous instance's line cannot answer for this one.
    since = since_stamp()
    _ = Shell.quietly(["sudo", "systemctl", "start", Config.unit()])
    {:reply, await(Config.unit(), "listening on", since, timeout_ms), state}
  end

  def handle_call({:wait_for_line, needle, timeout_ms}, _from, state) do
    {:reply, await(Config.unit(), needle, since_stamp(), timeout_ms), state}
  end

  def handle_call({:journal, unit}, _from, state) do
    reply =
      case Shell.run(["journalctl", "-u", unit || Config.unit(), "-o", "cat", "--no-pager"]) do
        {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  # ---------------------------------------------------------------- log following
  @doc false
  def since_stamp, do: "@" <> Integer.to_string(System.os_time(:second))

  @doc """
  Follow a unit's log and return the first line containing `needle`. The child process is the event
  source: its bytes arrive as port messages, so there is no polling and no sleep.
  """
  def await(unit, needle, since \\ "-1min", timeout_ms \\ 300_000) do
    case System.find_executable("timeout") do
      nil ->
        {:error, :no_timeout_binary}

      timeout ->
        args = [
          to_string(div(timeout_ms, 1000)),
          "journalctl",
          "-u",
          unit,
          "-f",
          "-o",
          "cat",
          "--since=#{since}"
        ]

        port = Port.open({:spawn_executable, timeout}, [:binary, :exit_status, :hide, args: args])
        collect(port, needle, "", System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp collect(port, needle, acc, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case BonsaiServing.Log.first_line(acc <> data, needle) do
          {:ok, line} ->
            close(port)
            {:ok, line}

          {:more, rest} ->
            collect(port, needle, rest, deadline)
        end

      {^port, {:exit_status, status}} ->
        close(port)
        {:error, {:exited, status, acc}}
    after
      wait ->
        close(port)
        {:error, :timeout}
    end
  end

  defp close(port) do
    # The pipe is ours to close; the child may be a `timeout` that would otherwise linger.
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> Shell.quietly(["kill", to_string(pid)])
      _ -> :ok
    end

    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end
end
