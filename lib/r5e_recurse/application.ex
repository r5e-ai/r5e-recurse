defmodule R5eRecurse.Application do
  @moduledoc "OTP application for the recorded development loop."
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: R5eRecurse.Supervisor)
  end
end
