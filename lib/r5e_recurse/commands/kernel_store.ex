defmodule R5eRecurse.Commands.KernelStore do
  @moduledoc "Command storage using the kernel client's canonical HTTP reads and signed admission."
  alias R5eRecurse.KernelClient

  def history(client) do
    with {:ok, events} <- apply(KernelClient, :events_from, [client, 1]),
         {:ok, _} <- RecurseVerify.Chain.verify_events(events) do
      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, records} ->
        with {:ok, bytes} <- apply(KernelClient, :get_cas, [client, event["payload"]]),
             {:ok, payload} <- RecurseVerify.Canonical.decode_json(bytes) do
          {:cont, {:ok, [%{event: event, payload: payload} | records]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    end
  end

  def submit(client, spec, envelope),
    do:
      apply(KernelClient, :submit, [client, R5eRecurse.Commands.Envelope.target(), envelope, spec])
end
