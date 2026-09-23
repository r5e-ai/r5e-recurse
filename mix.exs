defmodule R5eRecurse.MixProject do
  use Mix.Project

  def project do
    [
      app: :r5e_recurse,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:r5e_launcher] ++ Mix.compilers(),
      deps: [
        {:jason, "~> 1.4"},
        {:plug, "~> 1.20.3"},
        {:bandit, "~> 1.12.5"},
        {:recurse_verify,
         git: "https://gitlab.com/r5e-group/r5e-core.git",
         ref: "3ea5fb27fdfb001efbecc7ccc666845550ad7c43",
         subdir: "verifier"}
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :inets, :ssl], mod: {R5eRecurse.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Mix.Tasks.Compile.R5eLauncher do
  use Mix.Task.Compiler

  def run(_) do
    source = "priv/launcher/r5e_launch.c"
    output = "priv/launcher/r5e_launch"
    compiler = System.find_executable("cc") || Mix.raise("POSIX C compiler required")

    {text, status} =
      System.cmd(
        compiler,
        ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-o", output, source],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise(text)
    {:ok, []}
  end
end
