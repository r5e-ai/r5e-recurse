# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Supervisor do
  @moduledoc """
  Temporary execution workers. Explicit start is required for every invocation;
  restarting this supervisor never reconstructs or relaunches executions.
  """
  use DynamicSupervisor
  alias R5eRecurse.Execution.{Adapter.Prepared, Worker}

  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start supervision after admission. Success means starting, not observed launch."
  def start_execution(supervisor, %Prepared{} = prepared) do
    DynamicSupervisor.start_child(supervisor, %{
      id: make_ref(),
      start: {Worker, :start_link, [prepared]},
      restart: :temporary,
      shutdown: 1_000
    })
  end
end
