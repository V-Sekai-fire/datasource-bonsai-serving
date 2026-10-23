defmodule BonsaiServing.MixProject do
  use Mix.Project

  def project do
    [
      app: :bonsai_serving,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: [],
      escript: [main_module: BonsaiServing.CLI],
      aliases: [bonsai: "run -e 'BonsaiServing.CLI.main(System.argv())' --"]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl], mod: {BonsaiServing.Application, []}]
  end
end
