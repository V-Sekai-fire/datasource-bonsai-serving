defmodule BonsaiServing.Config do
  @moduledoc "Everything the ops app needs to know about this box. No defaults are guessed."

  @models "/opt/ninfer/models/bonsai2-27b-heretic.ninfer"
  @runner "/opt/ninfer-dev/bin/ninfer-serve"
  @libdir "/opt/ninfer/lib:/usr/lib/wsl/lib"
  @env_file "/etc/ninfer/env"
  @devices_file "/etc/ninfer/pipeline.devices"
  @unit "ninfer-serve"
  @unit_path "/etc/systemd/system/ninfer-serve.service"
  @port 8091

  @common_args [
    "--host",
    "127.0.0.1",
    "--model-id",
    "bonsai-27b",
    "--vision",
    "--max-concurrency",
    "3",
    "--spec",
    "dflash2",
    "--draft-tokens",
    "8",
    "--no-thinking"
  ]

  # The context-cache flags of ninfer-serve.service.d/latency.conf. The defaults (`private 2`, one
  # cached device state) let a resident long session push a growing agent conversation out, so every
  # agent turn re-prefilled; --concurrent-prefill lets a short request in while another prefills.
  @cache_args [
    "--max-private-continuations",
    "8",
    "--device-state-slots",
    "3",
    "--host-state-slots",
    "16",
    "--host-kv-mib",
    "16384",
    "--recency-eviction",
    "--concurrent-prefill"
  ]

  # The whole served argument list, as ninfer-serve.service with its latency.conf drop-in runs it.
  # `--devices 0,1` is part of it: the pins in pipeline.devices decide which cards those ordinals
  # are, and a variant measured against the unit has to start from the same list. The engine refuses
  # a --kv-capacity above --max-context x --max-concurrency, so the pool grows with concurrency.
  @unit_args ["--devices", "0,1"] ++
               @common_args ++
               ["--max-context", "262144", "--kv-capacity", "524288", "--kv-dtype", "rk8v4"] ++
               @cache_args

  @witness_prompt "Write a 150-word explanation of why the sky is blue."
  @witness_sha "d91927deb7e5d6dfd89919e9af780f667660100bf2a2b73a8690a3d0d457230e"

  def models, do: @models
  def runner, do: @runner
  def libdir, do: @libdir
  def env_file, do: @env_file
  def devices_file, do: @devices_file
  def unit, do: @unit
  def unit_path, do: @unit_path
  def port, do: @port
  def common_args, do: @common_args
  def unit_args, do: @unit_args
  def witness_prompt, do: @witness_prompt
  def witness_sha, do: @witness_sha

  def serve_args(port), do: @unit_args ++ ["--port", to_string(port)]

  @doc """
  Replace a flag's value in an argument list, or append the flag when it is absent. Appending a
  second copy of a flag the list already carries is how a probe silently measures the wrong thing.
  """
  def replace(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> args ++ [flag, value]
      index -> List.replace_at(args, index + 1, value)
    end
  end
end
