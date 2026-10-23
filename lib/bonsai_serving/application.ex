defmodule BonsaiServing.Application do
  @moduledoc """
  Supervision tree for the ops app. One long-lived process owns the systemd unit, so a caller never
  races two starts or two probes against each other.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [BonsaiServing.Unit]
    Supervisor.start_link(children, strategy: :one_for_one, name: BonsaiServing.Supervisor)
  end
end
