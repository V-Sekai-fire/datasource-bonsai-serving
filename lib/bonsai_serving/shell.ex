defmodule BonsaiServing.Shell do
  @moduledoc """
  Thin wrapper over System.cmd: every call returns {:ok, output} or an {:error, reason} tuple.
  `sudo` is used only where the box's file modes demand it.

  No error trapping: `try`, `rescue`, `catch` and `throw` are blocklisted in this workspace. The
  program is resolved with `System.find_executable/1` first, which is where the only raise used to
  come from, and anything else a program does to itself arrives as an exit code.
  """

  # On WSL the driver tools live outside the default PATH; `nvidia-smi` is in /usr/lib/wsl/lib.
  @extra_paths ["/usr/lib/wsl/lib"]

  @doc "Run a program, returning trimmed stdout. Options: `:extra_paths` adds directories to search."
  def run(argv, opts \\ []) do
    {cmd, args} = List.pop_at(argv, 0)
    extra = Keyword.get(opts, :extra_paths, @extra_paths)
    cmd_opts = Keyword.drop(opts, [:extra_paths])

    case which(cmd, extra) do
      {:ok, path} ->
        case System.cmd(path, args, [stderr_to_stdout: true] ++ cmd_opts) do
          {out, 0} -> {:ok, String.trim(out)}
          {out, code} -> {:error, {:exit, code, String.trim(out)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The full path of a program, searched on PATH and then in `extra`. A program that is nowhere is
  `{:error, {:not_found, cmd}}`, which is what makes the missing case a tagged tuple rather than a
  raise from System.cmd.
  """
  def which(cmd, extra \\ @extra_paths) do
    case System.find_executable(cmd) do
      nil ->
        case Enum.find(extra, fn dir -> File.exists?(Path.join(dir, cmd)) end) do
          nil -> {:error, {:not_found, cmd}}
          dir -> {:ok, Path.join(dir, cmd)}
        end

      path ->
        {:ok, path}
    end
  end

  @doc "Run a program and ignore whether it worked. Used for best-effort cleanup."
  def quietly(argv) do
    _ = run(argv)
    :ok
  end

  @doc "Run a program as root, for the paths under /etc/ninfer."
  def sudo(argv), do: run(["sudo", "-n" | argv])
end
