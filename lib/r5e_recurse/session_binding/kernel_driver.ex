defmodule R5eRecurse.SessionBinding.KernelDriver do
  @moduledoc """
  Journaled HTTP driver for SessionBinding. Uses the configured online kernel as
  admission authority; hash-checked chain/CAS reads are not an independent root pin.
  Recovered generations may be looked up in the journal, never re-registered as routes.
  """
  alias R5eRecurse.{NonceJournal, Commands.KernelStore}

  def new(journal, client, generation) do
    %{
      submit_once: fn operation, candidate, signer ->
        case NonceJournal.submit_once(journal, operation, generation, candidate, signer) do
          {:error, reason} -> {:not_submitted, reason}
          result -> result
        end
      end,
      read: fn ref -> read(client, ref) end
    }
  end

  @doc "Recover public journal operations without live keys or currently valid credentials. Never registers routes."
  def recover(journal, operation_ids) when is_list(operation_ids) do
    Map.new(operation_ids, fn id -> {id, NonceJournal.lookup(journal, id)} end)
  end

  defp read(client, ref) do
    with {:ok, records} <- KernelStore.history(client),
         %{event: %{"kind" => "admission.granted"}, payload: %{"outcome" => "admitted"} = payload} <-
           Enum.find(records, &("event:" <> &1.event["hash"] == ref)) do
      {:ok,
       %{
         spec: payload["spec"],
         target: payload["target"],
         actor: get_in(payload, ["actor", "id"]),
         signed: payload["signed"]
       }}
    else
      _ -> {:error, :canonical_admission_unavailable}
    end
  end
end
