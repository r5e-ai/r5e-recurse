defmodule R5eRecurse.Signer.Snapshot do
  @moduledoc """
  Fresh complete-history reads from the configured trusted online kernel.

  A second event-list read must exactly match the history whose payloads were
  fetched. A changing head is a refusal, never an automatic retry. This establishes
  a consistent observed head; it cannot independently prove that the configured
  server disclosed its latest history. Server authenticity and admitted core
  issuance semantics are trusted here. Authority rechecks credential signatures.

  `record/2` resolves immutable admission events and content-named Prompt artifacts
  inside this snapshot, rechecking their signatures and copied identity fields.
  It never consults a mutable resource projection or fetches a newer record.
  """
  alias R5eRecurse.{KernelClient, Commands.KernelStore, Commands.Envelope}
  alias RecurseVerify.{Canonical, Identity}

  def read(client, origin, clock \\ &DateTime.utc_now/0) do
    with true <- is_binary(origin) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, origin),
         {:ok, records} when records != [] <- KernelStore.history(client),
         {:ok, events} <- KernelClient.events_from(client, 1),
         true <- events == Enum.map(records, & &1.event),
         true <- Enum.all?(records, &origin?(&1.payload, origin)),
         %DateTime{} = observed_at <- clock.() do
      last = List.last(events)

      {:ok,
       %{
         origin: origin,
         complete: true,
         head: %{seq: last["seq"], hash: last["hash"]},
         observed_at: observed_at,
         records: Enum.map(records, &{&1.event, &1.payload})
       }}
    else
      _ -> {:error, :snapshot_unavailable}
    end
  rescue
    _ -> {:error, :snapshot_unavailable}
  catch
    _, _ -> {:error, :snapshot_unavailable}
  end

  def record(snapshot, reference, actor \\ nil)

  def record(snapshot, reference, actor) when is_binary(reference) do
    candidates =
      Enum.filter(snapshot.records, fn {_, p} = record ->
        matches?(record, reference) and (is_nil(actor) or get_in(p, ["actor", "id"]) == actor)
      end)

    # Content artifacts can be re-admitted. A pinned actor selects its latest
    # immutable admission; without a pin, cross-actor ambiguity is refused.
    actors = Enum.uniq(Enum.map(candidates, fn {_, p} -> get_in(p, ["actor", "id"]) end))

    with true <- length(actors) == 1,
         record = {event, payload} <- List.last(candidates),
         true <- event["kind"] == "admission.granted" and payload["outcome"] == "admitted",
         true <- payload["origin"] == snapshot.origin and payload["identity"] == "signed",
         {:ok, verified} <- Envelope.verify_signed(payload["signed"]),
         true <- verified.caller == verified.request["actor"],
         {_, [], %{signed: 1, admissions: 1, legacy: 0}} <- Identity.check_signatures([record]) do
      {:ok, %{ref: reference, kind: kind(payload), actor: verified.caller, spec: payload["spec"]}}
    else
      _ -> {:error, :record_unavailable}
    end
  rescue
    _ -> {:error, :record_unavailable}
  catch
    _, _ -> {:error, :record_unavailable}
  end

  def record(_, _, _), do: {:error, :record_unavailable}

  # Wrong-origin authentication denials can legitimately exist on this chain.
  defp origin?(%{"outcome" => "admitted", "origin" => origin}, origin), do: true
  defp origin?(%{"outcome" => "admitted"}, _), do: false
  defp origin?(_, _), do: true

  defp matches?({event, _}, "event:" <> hash), do: event["hash"] == hash

  defp matches?({_event, payload}, "gateway.r5e.io/v1alpha1/Prompt/" <> name) do
    payload["outcome"] == "admitted" and kind(payload) == "gateway.r5e.io/v1alpha1/Prompt" and
      payload["target"]["name"] == name and Canonical.hash(payload["spec"]) == name
  end

  defp matches?(_, _), do: false
  defp kind(payload), do: Enum.map_join(~w(group version kind), "/", &payload["target"][&1])
end
