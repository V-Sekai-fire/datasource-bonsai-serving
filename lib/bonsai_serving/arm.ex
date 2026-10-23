defmodule BonsaiServing.Arm do
  @moduledoc """
  A scratch server as a transient systemd unit, outside the agent's memory cgroup (a server started
  from inside the agent's own cgroup gets OOM-killed mid-load). `args` is the complete argument
  list, port included: nothing is implied.
  """
  alias BonsaiServing.{Config, Shell}

  def start(name, cuda_visible_devices, args) do
    unit = "ninfer-arm-#{name}"
    _ = Shell.quietly(["sudo", "systemctl", "stop", unit])
    _ = Shell.quietly(["sudo", "systemctl", "reset-failed", unit])

    argv =
      [
        "sudo",
        "systemd-run",
        "--unit=#{unit}",
        "--collect",
        "--property=User=fire",
        "--property=Type=exec",
        "--setenv=LD_LIBRARY_PATH=#{Config.libdir()}",
        "--setenv=CUDA_VISIBLE_DEVICES=#{cuda_visible_devices}",
        "--setenv=NINFER_BIN=#{Config.runner()}",
        Config.runner(),
        Config.models()
      ] ++ args

    case Shell.run(argv) do
      {:ok, _} -> {:ok, unit}
      {:error, reason} -> {:error, {:systemd_run, reason}}
    end
  end

  def stop(unit) do
    _ = Shell.quietly(["sudo", "systemctl", "stop", unit])
    _ = Shell.quietly(["sudo", "systemctl", "reset-failed", unit])
    :ok
  end
end
