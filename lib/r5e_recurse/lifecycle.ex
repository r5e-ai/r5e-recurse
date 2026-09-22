defmodule R5eRecurse.Lifecycle do
  @moduledoc """
  Pure replay of admitted workflow facts. Inputs are normalized maps with string
  keys `eventRef`, `seq`, `target`, `spec`, and `actor`. References retain the
  canonical `%{"$ref" => ...}` form. The caller must verify admission, authority,
  content hashes and Kind policy before supplying records; this is not a kernel
  verifier. Desired Task/Node resources are retained unchanged.

  Replay never recreates a live process, signer or route. Generations fence facts
  within an attempt; an interrupted attempt cannot resume or become successful.
  """
  import Kernel, except: [apply: 2]
  alias R5eRecurse.Lifecycle.Derived
  defstruct records: %{}, attempts: %{}, sequence: -1

  @active ~w(preparing ready running reflecting)
  @next %{
    "admitted" => ["preparing"],
    "preparing" => ["ready", "failed"],
    "ready" => ["running"],
    "running" => ["reflecting"],
    "reflecting" => ~w(completed declined failed),
    "cancellation_requested" => ~w(cancelled interrupted outcome_unknown)
  }

  def replay(records),
    do:
      Enum.reduce_while(records, {:ok, %__MODULE__{}}, fn r, {:ok, s} ->
        case apply(s, r) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)

  def apply(
        state,
        %{
          "eventRef" => %{"$ref" => id},
          "seq" => seq,
          "target" => %{"kind" => kind},
          "spec" => spec
        } = record
      )
      when is_binary(id) and is_integer(seq) do
    cond do
      seq <= state.sequence ->
        {:error, :out_of_order}

      Map.has_key?(state.records, id) ->
        {:error, :duplicate_event}

      true ->
        kind =
          if type?(record, kind), do: kind, else: nil

        with {:ok, next} <- reduce(state, kind, spec, record) do
          {:ok, %{next | sequence: seq, records: Map.put(next.records, id, record)}}
        end
    end
  end

  def apply(_, _), do: {:error, :invalid_record}

  defp reduce(state, "Task", spec, record) do
    with :ok <- retry_valid(state, spec, record) do
      attempt = %{task: record, status: "admitted", prior: nil, generation: nil, binding: nil}
      {:ok, %{state | attempts: Map.put(state.attempts, ref(record["eventRef"]), attempt)}}
    end
  end

  defp reduce(state, "LifecycleEvent", spec, record) do
    with {:ok, attempt} <- Map.fetch(state.attempts, ref(spec["task"])),
         :ok <- transition_valid(attempt, spec),
         :ok <- binding_valid(state, attempt, spec),
         :ok <- closure_valid(state, attempt, spec) do
      next = %{
        attempt
        | status: spec["transition"],
          prior: record["eventRef"],
          generation: spec["generation"],
          binding: spec["sessionBinding"] || attempt.binding
      }

      {:ok, %{state | attempts: Map.put(state.attempts, ref(spec["task"]), next)}}
    else
      :error -> {:error, :unknown_task}
      error -> error
    end
  end

  defp reduce(state, _, _, _), do: {:ok, state}

  defp transition_valid(a, s) do
    allowed =
      Map.get(@next, a.status, []) ++
        if(a.status in @active,
          do: ~w(cancellation_requested interrupted outcome_unknown),
          else: []
        )

    cond do
      s["priorLifecycle"] != a.prior ->
        {:error, :stale_predecessor}

      not generation?(s["generation"]) ->
        {:error, :missing_generation}

      a.generation != nil and a.generation != s["generation"] ->
        {:error, :stale_generation}

      s["transition"] not in allowed ->
        {:error, :illegal_transition}

      s["transition"] == "cancelled" and s["observationSource"] != "observed_stop" ->
        {:error, :stop_not_observed}

      true ->
        :ok
    end
  end

  defp generation?(%{"bootId" => b, "runId" => r}),
    do: is_binary(b) and b != "" and is_binary(r) and r != ""

  defp generation?(_), do: false

  defp binding_valid(state, a, s) do
    binding = s["sessionBinding"]

    cond do
      a.binding != nil and binding != a.binding ->
        {:error, :binding_changed}

      binding == nil and s["transition"] in ~w(ready running reflecting completed declined) ->
        {:error, :binding_required}

      binding == nil ->
        :ok

      reused_session?(state, a, binding) ->
        {:error, :retry_reused_session}

      true ->
        record = get(state, binding)

        cond do
          not type?(record, "SessionBinding") ->
            {:error, :unknown_binding}

          record["spec"]["task"] != a.task["eventRef"] or
              record["spec"]["generation"] != s["generation"] ->
            {:error, :binding_mismatch}

          true ->
            :ok
        end
    end
  end

  defp closure_valid(state, a, %{"transition" => "completed"} = s) do
    artifacts = Enum.map(s["outputs"] || [], &get(state, &1))
    binding = get(state, s["sessionBinding"])

    case get_in(binding, ["spec", "actorType"]) do
      "runtime_action" ->
        # The action-session key signs ToolCall; the runtime observer signs its
        # ActionResult/assessment. Observer authorization is checked at admission,
        # so a valid operational result need not share the binding's actor ID.
        if a.task["spec"]["step"] == "act" and
             Enum.any?(artifacts, fn record ->
               type?(record, "ActionResult") and
                 record["spec"]["sessionBinding"] == s["sessionBinding"] and
                 record["spec"]["assessment"] != nil and record["spec"]["outcome"] == "succeeded" and
                 action_tool?(get(state, record["spec"]["toolCall"]), binding)
             end), do: :ok, else: {:error, :operational_assessment_required}

      "agent" ->
        cond do
          not Derived.actual_reflection?(state, s["sessionBinding"], artifacts) ->
            {:error, :reflection_required}

          not Enum.any?(
            artifacts,
            &step_artifact?(&1, a.task["spec"]["step"], binding)
          ) ->
            {:error, :step_artifact_required}

          true ->
            :ok
        end

      _ ->
        {:error, :unknown_actor_type}
    end
  end

  defp closure_valid(_, _, _), do: :ok

  defp action_tool?(tool, binding) do
    type?(tool, "ToolCall", "gateway.r5e.io") and same_actor?(tool, binding) and
      binding["spec"]["agentSession"] != nil and
      tool["spec"]["session"] == binding["spec"]["agentSession"]
  end

  defp step_artifact?(%{"spec" => s} = artifact, step, binding) do
    types = %{
      "produce" => ~w(work lesson),
      "review" => ["review_findings"],
      "lesson_review" => ["review_findings"],
      "reflect" => ["reflection"],
      "evaluate" => ["evaluation"]
    }

    type?(artifact, "Artifact") and type?(binding, "SessionBinding") and
      same_actor?(artifact, binding) and s["type"] in Map.get(types, step, []) and
      s["sessionBinding"] == binding["eventRef"] and s["completeness"] == "complete"
  end

  defp step_artifact?(_, _, _), do: false

  @doc "Checks retry session freshness for a recorded binding, including before lifecycle attachment."
  def reused_session?(state, attempt, binding_ref) do
    earlier = state.attempts[ref(attempt.task["spec"]["earlierTask"])]
    old = if earlier, do: get(state, earlier.binding)
    current = get(state, binding_ref)

    type?(old, "SessionBinding") and type?(current, "SessionBinding") and
      (old["eventRef"] == current["eventRef"] or
         old["spec"]["agentSession"] == current["spec"]["agentSession"] or
         old["spec"]["sessionKey"] == current["spec"]["sessionKey"])
  end

  defp retry_valid(state, %{"earlierTask" => earlier} = spec, record) do
    old = state.attempts[ref(earlier)]
    decision = get(state, spec["recoveryDecision"])
    observation = get(state, get_in(decision || %{}, ["spec", "observationRef"]))
    interruption = if old, do: get(state, old.prior)

    cond do
      old == nil ->
        {:error, :unknown_prior_attempt}

      old.status not in ~w(interrupted outcome_unknown cancelled failed declined) ->
        {:error, :retry_not_terminal}

      old.task["spec"]["node"] != spec["node"] ->
        {:error, :retry_changed_node}

      old.task["spec"]["id"] == spec["id"] ->
        {:error, :retry_reused_task}

      not type?(decision, "RecoveryDecision") ->
        {:error, :recovery_required}

      decision["spec"]["disposition"] != "retry" or decision["spec"]["task"] != earlier or
          decision["spec"]["interruption"] != old.prior ->
        {:error, :recovery_mismatch}

      observation == nil or observation["seq"] <= interruption["seq"] or
        observation["seq"] >= decision["seq"] or decision["seq"] >= record["seq"] ->
        {:error, :reconciliation_required}

      not (type?(observation, "ActionResult") or type?(observation, "ReconciliationObservation")) ->
        {:error, :reconciliation_required}

      type?(observation, "ActionResult") and
          observation["spec"]["sessionBinding"] != old.binding ->
        {:error, :reconciliation_mismatch}

      type?(observation, "ReconciliationObservation") and
          observation["spec"]["interruption"] != old.prior ->
        {:error, :reconciliation_mismatch}

      true ->
        :ok
    end
  end

  defp retry_valid(_, _, _), do: :ok
  @doc "Checks the complete Kind identity; similarly named foreign Kinds remain ordinary facts."
  def type?(record, kind, group \\ "recurse.r5e.io", version \\ "v1alpha1")

  def type?(
        %{"target" => %{"group" => group, "version" => version, "kind" => kind}},
        kind,
        group,
        version
      ),
      do: true

  def type?(_, _, _, _), do: false

  @doc "Compares admitted actor IDs, without treating descriptive metadata as identity."
  def same_actor?(left, right) do
    id = actor_id(left)
    is_binary(id) and id != "" and id == actor_id(right)
  end

  defp actor_id(%{"actor" => %{"id" => id}}), do: id
  defp actor_id(_), do: nil

  def get(state, reference), do: state.records[ref(reference)]
  def ref(%{"$ref" => id}), do: id
  def ref(_), do: nil
end
