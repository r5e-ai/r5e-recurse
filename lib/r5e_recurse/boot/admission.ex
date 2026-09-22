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
  retries or replaces an uncertain request. `new/4` requires a live NonceJournal
  and current recovery generation. Semantic operation IDs exclude boot generation;
  old operations are lookup-only before new-generation preparation. Changed exact
  candidates conflict. Missing journal or issuer authority has no fallback. Discovering interrupted bindings and
  observing process ownership belong to the deployment's reconciliation driver.
  """
  alias R5eRecurse.{NonceJournal, Commands.Envelope, Commands.KernelStore}
  alias RecurseVerify.Canonical

  def new(client, origin, signer, opts) when is_binary(origin) and is_function(signer, 4) do
    journal = Keyword.fetch!(opts, :journal)
    generation = Keyword.fetch!(opts, :generation)
    true = is_pid(journal) and R5eRecurse.NonceJournal.Entry.generation?(generation)
    %{client: client, origin: origin, signer: signer, journal: journal, generation: generation}
  end

  def admit(boundary, kind, input) when kind in [:observation, :revocation] do
    with {:ok, id} <- operation_id(boundary.origin, kind, input),
         {:ok, target, spec, issuer, authority} <- intended(kind, input) do
      case NonceJournal.operation(boundary.journal, id) do
        {:ok, entry} ->
          if entry["origin"] == boundary.origin and
               entry["candidate"] == %{"target" => target, "spec" => spec} and
               (entry["status"] == "reserved" or
                  matches?(entry["request"], boundary, target, spec, issuer, authority)) do
            finish(
              boundary,
              kind,
              input,
              target,
              spec,
              issuer,
              checked_result(
                NonceJournal.lookup(boundary.journal, id),
                boundary,
                target,
                spec,
                issuer,
                authority
              )
            )
          else
            {:conflict, %{operation_id: id, reason: :candidate_changed}}
          end

        :missing ->
          with {:ok, ^target, ^spec, ^issuer, ^authority} <- candidate(boundary, kind, input) do
            signer = fn ->
              with {:ok, envelope} <- boundary.signer.(target, spec, issuer, authority),
                   {:ok, verified} <- Envelope.verify_signed(envelope),
                   true <-
                     verified.caller == issuer and
                       matches?(verified.request, boundary, target, spec, issuer, authority),
                   do: {:ok, envelope},
                   else: (_ -> {:error, :invalid_recovery_candidate})
            end

            result =
              NonceJournal.submit_once(
                boundary.journal,
                id,
                boundary.generation,
                %{target: target, spec: spec},
                signer
              )

            finish(
              boundary,
              kind,
              input,
              target,
              spec,
              issuer,
              checked_result(result, boundary, target, spec, issuer, authority)
            )
          end
      end
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :recovery_boundary_unavailable}}
  catch
    _, _ -> {:outcome_unknown, %{reason: :recovery_boundary_unavailable}}
  end

  def admit(_, _, _), do: {:error, :recovery_kind_forbidden}

  # Another caller can reserve this operation after the metadata read. Bind the
  # recovered envelope again; a same-spec race cannot substitute its authority.
  defp checked_result({tag, _, envelope} = result, boundary, target, spec, issuer, authority)
       when tag in [:ok, :denied] do
    with {:ok, verified} <- Envelope.verify_signed(envelope),
         true <-
           verified.caller == issuer and
             matches?(verified.request, boundary, target, spec, issuer, authority) do
      result
    else
      _ -> {:conflict, %{reason: :recovery_authority_changed}}
    end
  end

  defp checked_result(result, _, _, _, _, _), do: result

  defp matches?(request, boundary, target, spec, issuer, authority),
    do:
      request["actor"] == issuer and request["origin"] == boundary.origin and
        request["target"] == target and request["specAddress"] == Canonical.hash(spec) and
        request["authority"] == authority

  defp finish(boundary, kind, input, target, spec, issuer, {:ok, receipt, envelope}),
    do: confirm(boundary, kind, input, target, spec, issuer, envelope, receipt)

  defp finish(_, _, _, _, _, _, {:denied, receipt, _}), do: {:denied, receipt}

  defp finish(_, _, _, _, _, _, {:outcome_unknown, %{event_ref_hint: ref} = details}),
    do:
      {:outcome_unknown,
       Map.merge(details, %{event_ref: ref, reason: :canonical_confirmation_unavailable})}

  defp finish(_, _, _, _, _, _, result), do: result

  defp intended(:revocation, %{badge: badge, issuer: issuer})
       when is_binary(badge) and is_binary(issuer),
       do:
         {:ok, target("core.r5e.io", "v1", "Revocation"), %{"revokes" => %{"$ref" => badge}},
          issuer, []}

  defp intended(:observation, candidate), do: candidate(nil, :observation, candidate)
  defp intended(_, _), do: {:error, :invalid_recovery_candidate}

  defp operation_id(origin, :revocation, %{badge: badge}) when is_binary(badge),
    do:
      {:ok,
       Canonical.hash(%{"origin" => origin, "stage" => "issuer-revocation", "badge" => badge})}

  defp operation_id(origin, :observation, %{
         spec: %{"interruption" => %{"$ref" => interruption}} = spec
       })
       when is_binary(interruption),
       do:
         {:ok,
          Canonical.hash(%{
            "origin" => origin,
            "stage" => "reconciliation-observation",
            "target" => Map.take(spec, ~w(interruption sessionBinding action))
          })}

  defp operation_id(_, _, _), do: {:error, :invalid_recovery_identity}

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
