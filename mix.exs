defmodule R5eRecurse.MixProject do
  use Mix.Project

  def project do
    [
      app: :r5e_recurse,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:jason, "~> 1.4"}, {:plug, "~> 1.20.3"}, {:bandit, "~> 1.12.5"}]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :inets, :ssl], mod: {R5eRecurse.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
