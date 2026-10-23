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
    "1",
    "--spec",
    "dflash2",
    "--draft-tokens",
    "5",
    "--no-thinking"
  ]

  @unit_args @common_args ++ ["--max-context", "262144", "--kv-capacity", "262144", "--kv-dtype", "rk8v4"]

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
end
