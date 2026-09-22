defmodule R5eRecurse.Boot.Discovery do
  @moduledoc """
  Read-only online boot inventory. The configured kernel is trusted to serve its
  authentic, complete, latest admitted history and to have enforced Kind policy.
  Hashes, signatures and copied request identity are checked locally; these do
  not independently authenticate the kernel's head or prove offline admission.

  Two identical full event reads bracket CAS loading. A changing head fails
  without retry. The returned checkpoint describes that snapshot, not a lock
  against subsequent admission. No result is a gate-opening or revocation grant.
  Journal-only reservations and process ownership require separate integration.
  """
  alias R5eRecurse.{Commands.Envelope, Commands.KernelStore, KernelClient, Lifecycle}
  alias RecurseVerify.Identity

  def read(client, origin, current_boot)
      when is_binary(origin) and origin != "" and is_binary(current_boot) and current_boot != "" do
    with {:ok, records} <- KernelStore.history(client),
         {:ok, second} <- KernelClient.events_from(client, 1),
         true <- Enum.map(records, & &1.event) == second,
         {:ok, normalized} <- verify(records, origin),
         {:ok, state} <- Lifecycle.replay(normalized) do
      {:ok, inventory(normalized, state, second, origin, current_boot)}
    else
      false -> {:error, :changing_head}
      error -> error
    end
  rescue
    _ -> {:error, :malformed_discovery_history}
  end

  def read(_, _, _), do: {:error, :invalid_discovery_options}

  defp verify(records, origin) do
    # Only cited core credentials enter the inventory. Unrelated Badges are not
    # recovery targets, even if their subject resembles a local session key.
    workflow = Enum.filter(records, &workflow?(&1.payload))

    refs =
      workflow
      |> Enum.flat_map(fn %{event: e, payload: p} ->
        if e["kind"] == "admission.granted" and p["outcome"] == "admitted" and
             Lifecycle.type?(p, "SessionBinding"),
           do:
             Enum.map(~w(badge delegation agentSessionAdmission), &Lifecycle.ref(p["spec"][&1])),
           else: []
      end)
      |> MapSet.new()

    selected =
      Enum.filter(records, &(workflow?(&1.payload) or MapSet.member?(refs, event_ref(&1.event))))

    Enum.reduce_while(selected, {:ok, []}, fn %{event: e, payload: p}, {:ok, acc} ->
      if e["kind"] == "admission.granted" or p["outcome"] == "admitted" do
        with true <- e["kind"] == "admission.granted" and p["outcome"] == "admitted",
             true <- p["origin"] == origin and p["identity"] == "signed",
             {:ok, _} <- Envelope.verify_signed(p["signed"]),
             {_, [], %{signed: 1, admissions: 1, legacy: 0}} <-
               Identity.check_signatures([{e, p}]) do
          r = Map.take(p, ~w(target spec actor authority))
          r = Map.merge(r, %{"eventRef" => %{"$ref" => event_ref(e)}, "seq" => e["seq"]})
          {:cont, {:ok, [r | acc]}}
        else
          _ -> {:halt, {:error, {:unverified_admission, event_ref(e)}}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp workflow?(%{"target" => %{"group" => "recurse.r5e.io", "version" => "v1alpha1"}}), do: true
  defp workflow?(p), do: Lifecycle.type?(p, "ToolCall", "gateway.r5e.io")

  defp inventory(records, state, events, origin, boot) do
    bindings = Enum.filter(records, &Lifecycle.type?(&1, "SessionBinding"))
    counts = Enum.frequencies_by(bindings, &Lifecycle.ref(&1["spec"]["task"]))
    entries = Enum.map(bindings, &entry(&1, records, state, counts, boot))
    grouped = Enum.group_by(entries, & &1.classification)

    %{
      origin: origin,
      current_boot_id: boot,
      checkpoint:
        case List.last(events) do
          nil -> %{"seq" => 0, "hash" => RecurseVerify.Chain.genesis()}
          event -> Map.take(event, ~w(seq hash))
        end,
      bindings: entries,
      current_boot: Map.get(grouped, :current_boot, []),
      old_terminal: Map.get(grouped, :old_terminal, []),
      old_interrupted: Map.get(grouped, :old_interrupted, []),
      old_active: Map.get(grouped, :old_active, []),
      unattached: Enum.filter(entries, &(not &1.lifecycle_attached)),
      attempts: state.attempts,
      blockers: Enum.flat_map(entries, & &1.blockers),
      integration_dependencies: [
        :journal_reserved_intents,
        :partial_setup_provenance,
        :process_ownership,
        :admission_gate_wiring
      ],
      complete_boot: false
    }
  end

  defp entry(binding, records, state, counts, boot) do
    s = binding["spec"]
    task_ref = Lifecycle.ref(s["task"])
    attempt = state.attempts[task_ref]
    badge = Lifecycle.get(state, s["badge"])
    delegation = Lifecycle.get(state, s["delegation"])
    span = Lifecycle.get(state, s["agentSessionAdmission"])
    actor = get_in(binding, ["actor", "id"])
    generation = s["generation"]

    preparation =
      Enum.find(records, fn r ->
        Lifecycle.type?(r, "LifecycleEvent") and r["spec"]["task"] == s["task"] and
          r["spec"]["transition"] == "preparing" and r["spec"]["generation"] == generation and
          r["seq"] < binding["seq"]
      end)

    credentials = [badge, delegation, span]

    prepared =
      preparation != nil and
        Enum.all?(credentials, &(&1 != nil and preparation["seq"] < &1["seq"]))

    provenance =
      attempt != nil and Lifecycle.type?(badge, "Badge", "core.r5e.io", "v1") and
        Lifecycle.type?(delegation, "Endorsement", "core.r5e.io", "v1") and
        Lifecycle.type?(span, "AgentSession", "gateway.r5e.io") and
        Enum.all?(credentials, &(&1["seq"] < binding["seq"])) and
        badge["spec"]["subject"] == actor and delegation["spec"]["subject"] == actor and
        s["sessionKey"] == actor and get_in(span, ["actor", "id"]) == actor and
        Lifecycle.ref(s["agentSession"]) == resource_ref(span) and
        attempt.task["seq"] < binding["seq"] and
        get_in(delegation, ["actor", "id"]) == attempt.task["spec"]["delegatedBy"] and
        get_in(badge, ["spec", "scope", "task"]) == task_ref and
        get_in(delegation, ["spec", "scope", "task"]) == task_ref and
        Lifecycle.ref(s["badge"]) in (binding["authority"] || []) and
        Lifecycle.ref(s["delegation"]) in (binding["authority"] || [])

    valid_generation =
      is_map(generation) and is_binary(generation["bootId"]) and generation["bootId"] != "" and
        is_binary(generation["runId"]) and generation["runId"] != "" and
        attempt != nil and generation == attempt.generation

    closure = if attempt, do: Lifecycle.get(state, attempt.prior)

    after_closure =
      attempt != nil and
        attempt.status in ~w(completed declined failed cancelled interrupted outcome_unknown) and
        closure != nil and closure["seq"] < binding["seq"]

    reused_session =
      attempt != nil and Lifecycle.reused_session?(state, attempt, binding["eventRef"])

    reasons =
      []
      |> block(not prepared, :missing_durable_preparation)
      |> block(not provenance, :unresolved_binding_provenance)
      |> block(not valid_generation, :generation_mismatch)
      |> block(counts[task_ref] > 1, :ambiguous_attempt_bindings)
      |> block(after_closure, :binding_after_closure)
      |> block(reused_session, :retry_reused_session)

    status = if attempt, do: attempt.status

    classification =
      cond do
        not provenance or not valid_generation -> :unattached
        generation["bootId"] == boot -> :current_boot
        status in ~w(interrupted outcome_unknown) -> :old_interrupted
        status in ~w(completed declined failed cancelled) -> :old_terminal
        true -> :old_active
      end

    ref = Lifecycle.ref(binding["eventRef"])

    %{
      binding: ref,
      task: task_ref,
      generation: generation,
      status: status,
      classification: classification,
      lifecycle_attached: attempt != nil and attempt.binding == binding["eventRef"],
      badge: Lifecycle.ref(s["badge"]),
      delegation: Lifecycle.ref(s["delegation"]),
      issuer: if(badge, do: get_in(badge, ["actor", "id"])),
      subject: if(badge, do: get_in(badge, ["spec", "subject"])),
      agent_session_admission: Lifecycle.ref(s["agentSessionAdmission"]),
      prior_lifecycle: if(attempt, do: attempt.prior),
      preparation: if(preparation, do: preparation["eventRef"]),
      blockers: Enum.map(reasons, &%{binding: ref, reason: &1})
    }
  end

  # The server-named AgentSession admission target can omit its generated name.
  # The canonical name is then the exact admission event reference, never a
  # current resource projection or a descriptive session identifier.
  defp resource_ref(%{
         "target" =>
           %{"group" => "gateway.r5e.io", "version" => "v1alpha1", "kind" => "AgentSession"} =
             target,
         "eventRef" => %{"$ref" => event_ref}
       }) do
    name = target["name"] || event_ref
    if is_binary(name) and name != "", do: "gateway.r5e.io/v1alpha1/AgentSession/" <> name
  end

  defp resource_ref(_), do: nil

  defp block(reasons, true, reason), do: reasons ++ [reason]
  defp block(reasons, false, _), do: reasons
  defp event_ref(event), do: "event:" <> event["hash"]
end
