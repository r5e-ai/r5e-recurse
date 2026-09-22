defmodule R5eRecurse.Lifecycle.Derived do
  @moduledoc """
  Read-only projections over the trusted admitted-record boundary of Lifecycle.
  Decisions are distinct from recommendations; all joins use exact event refs.
  Authorization, verified CAS bytes, and parsed-findings equality belong to
  admission policy, not these projections.
  """
  alias R5eRecurse.Lifecycle

  def artifact(state, target) do
    if Lifecycle.type?(Lifecycle.get(state, target), "Artifact"),
      do: advance(state, target),
      else: {:error, :unknown_artifact}
  end

  defp advance(state, target) do
    reviews =
      records(state, "Review")
      |> Enum.filter(&(&1["spec"]["target"] == target and independent?(state, &1)))

    decisions =
      records(state, "Decision")
      |> Enum.filter(fn d ->
        d["spec"]["target"] == target and
          Enum.any?(reviews, &(&1["eventRef"] == d["spec"]["review"] and &1["seq"] < d["seq"]))
      end)

    case List.last(decisions) do
      nil ->
        if reviews == [], do: pending(state, target), else: "reviewed"

      d ->
        Map.get(
          %{
            "accept" => "accepted",
            "revise" => "revision_requested",
            "decline" => "declined",
            "escalate" => "escalated"
          },
          d["spec"]["disposition"],
          "reviewed"
        )
    end
  end

  # A review Task explicitly citing this immutable input establishes pending work.
  defp pending(state, target) do
    if Enum.any?(records(state, "Task"), fn t ->
         t["spec"]["step"] in ~w(review lesson_review) and t["spec"]["target"] == target
       end), do: "review_pending", else: "produced"
  end

  def independent?(state, review) do
    artifact = Lifecycle.get(state, review["spec"]["target"])
    producer_ref = get_in(artifact || %{}, ["spec", "sessionBinding"])
    reviewer_ref = review["spec"]["sessionBinding"]
    producer = Lifecycle.get(state, producer_ref)
    reviewer = Lifecycle.get(state, reviewer_ref)
    findings = Lifecycle.get(state, review["spec"]["findings"])
    p = (producer || %{})["spec"] || %{}
    r = (reviewer || %{})["spec"] || %{}

    Lifecycle.type?(review, "Review") and Lifecycle.type?(artifact, "Artifact") and
      Lifecycle.type?(producer, "SessionBinding") and Lifecycle.type?(reviewer, "SessionBinding") and
      Lifecycle.same_actor?(artifact, producer) and Lifecycle.same_actor?(review, reviewer) and
      findings_valid?(findings, reviewer_ref, review) and
      producer_ref != reviewer_ref and
      p["provider"] != nil and r["provider"] != nil and p["provider"] != r["provider"] and
      p["sessionKey"] != nil and r["sessionKey"] != nil and p["sessionKey"] != r["sessionKey"] and
      p["agentSession"] != nil and r["agentSession"] != nil and
      p["agentSession"] != r["agentSession"]
  end

  defp findings_valid?(
         %{"spec" => f} = findings,
         binding,
         review
       ) do
    Lifecycle.type?(findings, "Artifact") and f["type"] == "review_findings" and
      f["sessionBinding"] == binding and
      f["completeness"] == "complete" and Lifecycle.same_actor?(findings, review) and
      findings["seq"] < review["seq"]
  end

  defp findings_valid?(_, _, _), do: false

  def actual_reflection?(state, binding, artifacts) do
    b = Lifecycle.get(state, binding)

    Enum.any?(artifacts, fn
      %{"spec" => s} = artifact ->
        Lifecycle.type?(artifact, "Artifact") and Lifecycle.type?(b, "SessionBinding") and
          s["type"] == "reflection" and s["completeness"] == "complete" and
          s["sessionBinding"] == binding and get_in(b || %{}, ["spec", "actorType"]) == "agent" and
          Lifecycle.same_actor?(artifact, b) and s["content"] != nil

      _ ->
        false
    end)
  end

  def reflection(state, task) do
    case state.attempts[Lifecycle.ref(task)] do
      nil ->
        {:error, :unknown_task}

      a ->
        cond do
          actual_reflection?(state, a.binding, records(state, "Artifact")) ->
            "available"

          Enum.any?(
            records(state, "RecoveryDecision"),
            &(&1["spec"]["task"] == task and &1["spec"]["disposition"] == "finalize_incomplete")
          ) ->
            "unavailable_acknowledged"

          a.status in ~w(interrupted outcome_unknown) ->
            "interrupted"

          true ->
            "pending"
        end
    end
  end

  def lesson_eligible?(state, target) do
    lesson = Lifecycle.get(state, target)

    Lifecycle.type?(lesson, "Artifact") and get_in(lesson, ["spec", "type"]) == "lesson" and
      get_in(lesson, ["spec", "completeness"]) == "complete" and
      artifact(state, target) == "accepted" and
      not Enum.any?(records(state, "Artifact"), fn replacement ->
        replacement["spec"]["type"] == "lesson" and
          replacement["spec"]["earlierArtifact"] == target and
          artifact(state, replacement["eventRef"]) == "accepted"
      end) and
      not Enum.any?(records(state, "LessonWithdrawal"), &(&1["spec"]["lesson"] == target))
  end

  defp records(state, kind) do
    state.records
    |> Map.values()
    |> Enum.filter(&Lifecycle.type?(&1, kind))
    |> Enum.sort_by(& &1["seq"])
  end
end
