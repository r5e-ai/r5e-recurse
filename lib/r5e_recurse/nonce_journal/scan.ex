defmodule R5eRecurse.NonceJournal.Scan do
  @moduledoc "Resolve a journaled request from hash-checked canonical history; never resubmit."
  alias R5eRecurse.Commands.{Envelope, KernelStore}
  alias R5eRecurse.NonceJournal.Entry
  alias RecurseVerify.Canonical

  def lookup(client, entry) do
    with {:ok, records} <- KernelStore.history(client), do: resolve(records, entry)
  end

  def resolve(records, entry) do
    if Entry.valid?(entry, entry["origin"]) and entry["status"] == "prepared" do
      do_resolve(records, entry)
    else
      {:outcome_unknown, %{reason: :invalid_journal_entry}}
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :malformed_history}}
  end

  defp do_resolve(records, entry) do
    request = entry["request"]

    first =
      Enum.reduce_while(records, :none, fn %{event: event, payload: p} = record, _ ->
        if get_in(p, ["actor", "id"]) == request["actor"] and p["nonce"] == request["nonce"] do
          with {:ok, v} <- Envelope.verify_signed(p["signed"]),
               true <- v.caller == get_in(p, ["actor", "id"]) and v.request["nonce"] == p["nonce"],
               true <-
                 v.request["origin"] == p["origin"] and
                   v.request["target"] == p["submittedTarget"] do
            case consuming?(event, p, v) do
              false -> {:cont, :none}
              true -> {:halt, {:found, record, v}}
              :invalid -> {:halt, :invalid}
            end
          else
            _ -> {:halt, :invalid}
          end
        else
          {:cont, :none}
        end
      end)

    case first do
      :none ->
        {:outcome_unknown, %{reason: :not_observed}}

      {:found, %{event: event, payload: p}, verified} ->
        if verified.request == request and verified.caller == request["actor"] and
             entry["candidate"]["target"] == request["target"] and
             p["spec"] == entry["candidate"]["spec"] and
             Canonical.hash(p["spec"]) == request["specAddress"] do
          receipt = %{
            "eventRef" => "event:" <> event["hash"],
            "event" => event["hash"],
            "seq" => event["seq"],
            "outcome" => p["outcome"],
            "recorded" => true,
            "identity" => "signed"
          }

          {if(p["outcome"] == "admitted", do: :ok, else: :denied), receipt, entry["envelope"]}
        else
          {:outcome_unknown, %{reason: :candidate_or_outcome_unconfirmed}}
        end

      _ ->
        {:outcome_unknown, %{reason: :malformed_history}}
    end
  end

  defp consuming?(
         %{"kind" => "admission.denied"},
         %{"outcome" => "denied", "reason" => "authenticate: actor mismatch: " <> _},
         verified
       ) do
    if verified.request["actor"] != verified.caller, do: false, else: :invalid
  end

  defp consuming?(
         %{"kind" => "admission.denied"},
         %{"outcome" => "denied", "reason" => "authenticate: nonce replayed: " <> _},
         _
       ),
       do: false

  defp consuming?(
         %{"kind" => "admission.denied"},
         %{"outcome" => "denied", "reason" => reason},
         _
       )
       when is_binary(reason) do
    if hd(String.split(reason, ": ", parts: 2)) in ~w(authenticate validateStructure resolve authorize validateConstraints record admit),
      do: true,
      else: :invalid
  end

  defp consuming?(%{"kind" => "admission.granted"}, %{"outcome" => "admitted"}, _), do: true
  defp consuming?(_, _, _), do: :invalid
end
