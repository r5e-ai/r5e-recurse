defmodule Mix.Tasks.Recurse.Bootstrap do
  use Mix.Task
  @shortdoc "Admit Recurse definitions and policy through a configured deployment driver"
  @moduledoc "Requires Application configuration :r5e_recurse, :bootstrap_driver (a two-argument function). The driver selects the chain and external operator signer; this task accepts no raw keys."

  def run(args) do
    if args != [],
      do: Mix.raise("recurse.bootstrap accepts no arguments; configure the deployment driver")

    Mix.Task.run("app.start")
    driver = Application.get_env(:r5e_recurse, :bootstrap_driver)

    unless is_function(driver, 2),
      do:
        Mix.raise(
          "configure :r5e_recurse, :bootstrap_driver with the deployment transport and external operator signer"
        )

    case R5eRecurse.Bootstrap.run(driver) do
      {:ok, rows} ->
        Enum.each(rows, fn row ->
          Mix.shell().info(
            "#{row.status} #{row.candidate.group}/#{row.candidate.version}/#{row.candidate.kind}"
          )
        end)

      _ ->
        Mix.raise(
          "bootstrap stopped; inspect the driver's credential-safe diagnostics before resolving or retrying"
        )
    end
  end
end
