defmodule R5eRecurse.Boot.Admission do
  @moduledoc """
  Canonical recovery admission boundary for `Boot`.

  Uses the configured kernel endpoint as the admission authority, checks the
  complete returned chain and CAS digests, and verifies the submitted signature
  and exact recorded request. This is an online boundary, not an independently
  pinned offline checkpoint verifier. The signer callback retains issuer custody.

  A revocation candidate names `badge` and its original `issuer`; an observation
  candidate names `issuer`, `authority` and `spec`. The callback receives
  `(target, spec, issuer, authority)` and returns `{:ok, envelope}`. Recovery never
  retries or replaces an uncertain request. Discovering interrupted bindings and
  observing process ownership belong to the deployment's reconciliation driver.
  """
  alias R5eRecurse.{KernelClient, Commands.Envelope, Commands.KernelStore}
  alias RecurseVerify.Canonical

  def new(client, origin, signer) when is_binary(origin) and is_function(signer, 4),
    do: %{client: client, origin: origin, signer: signer}

  def admit(boundary, kind, candidate) when kind in [:observation, :revocation] do
    with {:ok, target, spec, issuer, authority} <- candidate(boundary, kind, candidate),
         {:ok, envelope} <- boundary.signer.(target, spec, issuer, authority),
         {:ok, verified} <- Envelope.verify_signed(envelope),
         true <-
           verified.caller == issuer and verified.request["actor"] == issuer and
             verified.request["origin"] == boundary.origin and
             verified.request["target"] == target and
             verified.request["specAddress"] == Canonical.hash(spec) and
             verified.request["authority"] == authority do
      submit_confirm(boundary, kind, candidate, target, spec, issuer, envelope)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recovery_candidate}
    end
  rescue
    _ -> {:error, :recovery_preparation_failed}
  catch
    _, _ -> {:error, :recovery_preparation_failed}
  end

  def admit(_, _, _), do: {:error, :recovery_kind_forbidden}

  defp submit_confirm(boundary, kind, candidate, target, spec, issuer, envelope) do
    case KernelClient.submit(boundary.client, target, envelope, spec) do
      {:ok, receipt} ->
        confirm(boundary, kind, candidate, target, spec, issuer, envelope, receipt)

      {tag, _} = result
      when tag in [:error, :denied, :refused, :transport_failure, :outcome_unknown] ->
        result

      _ ->
        {:outcome_unknown, %{reason: :malformed_submission_response}}
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :submission_failed}}
  catch
    _, _ -> {:outcome_unknown, %{reason: :submission_failed}}
  end

  defp confirm(boundary, kind, candidate, target, spec, issuer, envelope, receipt) do
    with {:ok, records} <- KernelStore.history(boundary.client),
         %{event: event, payload: payload} <-
           Enum.find(records, &("event:" <> &1.event["hash"] == receipt["eventRef"])),
         true <-
           event["kind"] == "admission.granted" and payload["outcome"] == "admitted" and
             payload["identity"] == "signed" and payload["signed"] == envelope and
             payload["origin"] == boundary.origin and payload["spec"] == spec and
             get_in(payload, ["actor", "id"]) == issuer and
             Map.take(payload["target"], ~w(group version kind)) == Map.drop(target, ["name"]) do
      result = %{kind: kind, event_ref: receipt["eventRef"]}

      {:ok,
       if(kind == :revocation,
         do: Map.merge(result, Map.take(candidate, [:badge, :issuer])),
         else: result
       )}
    else
      _ -> unconfirmed(receipt)
    end
  rescue
    _ -> unconfirmed(receipt)
  catch
    _, _ -> unconfirmed(receipt)
  end

  defp unconfirmed(receipt),
    do:
      {:outcome_unknown,
       %{event_ref: receipt["eventRef"], reason: :canonical_confirmation_unavailable}}

  defp candidate(boundary, :revocation, %{badge: badge, issuer: issuer}) do
    target = target("core.r5e.io", "v1", "Revocation")

    with {:ok, records} <- KernelStore.history(boundary.client),
         %{event: event, payload: payload} <-
           Enum.find(records, &("event:" <> &1.event["hash"] == badge)),
         true <- event["kind"] == "admission.granted" and payload["outcome"] == "admitted",
         %{"group" => "core.r5e.io", "version" => "v1", "kind" => "Badge"} <- payload["target"],
         ^issuer <- get_in(payload, ["actor", "id"]),
         true <- payload["origin"] == boundary.origin do
      {:ok, target, %{"revokes" => %{"$ref" => badge}}, issuer, []}
    else
      _ -> {:error, :badge_issuer_unconfirmed}
    end
  end

  defp candidate(_, :observation, %{issuer: issuer, authority: authority, spec: spec})
       when is_binary(issuer) and is_list(authority) and is_map(spec),
       do:
         {:ok, target("recurse.r5e.io", "v1alpha1", "ReconciliationObservation"), spec, issuer,
          authority}

  defp candidate(_, _, _), do: {:error, :invalid_recovery_candidate}

  defp target(group, version, kind),
    do: %{"group" => group, "version" => version, "kind" => kind, "name" => nil}
end
