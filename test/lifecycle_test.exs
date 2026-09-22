defmodule R5eRecurse.LifecycleTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Lifecycle, as: L
  alias R5eRecurse.Lifecycle.Derived, as: D

  defp fixtures,
    do: __DIR__ |> Path.join("fixtures/events/lifecycle.json") |> File.read!() |> Jason.decode!()

  defp ref(id), do: %{"$ref" => "e:" <> id}

  defp event(kind, id, seq, spec, actor \\ "runtime"),
    do: %{
      "eventRef" => ref(id),
      "seq" => seq,
      "target" => %{
        "group" => "recurse.r5e.io",
        "version" => "v1alpha1",
        "kind" => kind,
        "name" => id
      },
      "spec" => spec,
      "actor" => %{"id" => actor}
    }

  defp transition(status, seq, prior, extra \\ %{}) do
    spec =
      List.last(fixtures())["spec"]
      |> Map.merge(%{"transition" => status, "priorLifecycle" => ref(prior)})
      |> Map.merge(extra)

    event("LifecycleEvent", status, seq, spec)
  end

  defp through(n), do: fixtures() |> Enum.take(n) |> L.replay()

  test "canonical-shaped admitted facts replay without changing intent" do
    records = fixtures()
    assert {:ok, a} = L.replay(records)
    assert {:ok, ^a} = Enum.reduce(records, {:ok, %L{}}, fn r, {:ok, s} -> L.apply(s, r) end)
    assert a.attempts["e:task"].status == "completed"
    assert a.attempts["e:task"].task == hd(records)
    assert D.reflection(a, ref("task")) == "available"
    assert D.artifact(a, ref("work")) == "produced"
  end

  test "completion requires admitted exact step artifact and actual session reflection" do
    {:ok, s} = through(7)
    assert {:error, :reflection_required} = L.apply(s, List.last(fixtures()))
    fake = Enum.at(fixtures(), 7) |> Map.put("actor", %{"id" => "runtime"})
    {:ok, s} = L.apply(s, fake)
    assert {:error, :reflection_required} = L.apply(s, List.last(fixtures()))
    {:ok, s} = through(8)

    assert {:error, :step_artifact_required} =
             L.apply(
               s,
               transition("completed", 9, "reflecting", %{"outputs" => [ref("reflection")]})
             )

    assert {:error, :reflection_required} =
             L.apply(s, transition("completed", 9, "reflecting", %{"outputs" => [ref("work")]}))
  end

  test "state, predecessor and generation errors refuse without changing state" do
    {:ok, s} = through(5)
    assert {:error, :illegal_transition} = L.apply(s, transition("completed", 10, "running"))
    assert {:error, :stale_predecessor} = L.apply(s, transition("reflecting", 10, "ready"))

    assert {:error, :stale_generation} =
             L.apply(
               s,
               transition("reflecting", 10, "running", %{
                 "generation" => %{"bootId" => "old", "runId" => "run-1"}
               })
             )

    assert {:error, :out_of_order} = L.apply(s, Enum.at(fixtures(), 4))
    assert {:ok, s} = L.apply(s, transition("interrupted", 10, "running"))

    assert {:error, :illegal_transition} =
             L.apply(
               s,
               Map.put(transition("running", 11, "interrupted"), "eventRef", ref("resume"))
             )

    assert D.reflection(s, ref("task")) == "interrupted"
  end

  test "preparation can fail or cancel before session credentials exist" do
    {:ok, s} = through(2)

    assert {:ok, failed} =
             L.apply(s, transition("failed", 3, "prepare", %{"sessionBinding" => nil}))

    assert failed.attempts["e:task"].binding == nil
    assert D.reflection(failed, ref("task")) == "pending"

    assert {:ok, s} =
             L.apply(
               s,
               transition("cancellation_requested", 3, "prepare", %{"sessionBinding" => nil})
             )

    assert {:error, :stop_not_observed} =
             L.apply(
               s,
               transition("cancelled", 4, "cancellation_requested", %{
                 "sessionBinding" => nil,
                 "observationSource" => "timeout"
               })
             )

    assert {:ok, s} =
             L.apply(
               s,
               transition("cancelled", 4, "cancellation_requested", %{
                 "sessionBinding" => nil,
                 "observationSource" => "observed_stop"
               })
             )

    assert s.attempts["e:task"].status == "cancelled"
  end

  test "retry preserves Node and requires newer reconciliation and new Task/session" do
    {:ok, s} = through(5)
    {:ok, s} = L.apply(s, transition("interrupted", 6, "running"))

    {:ok, s} =
      L.apply(
        s,
        event("ReconciliationObservation", "observation", 7, %{
          "interruption" => ref("interrupted"),
          "result" => "stopped"
        })
      )

    {:ok, s} =
      L.apply(
        s,
        event("RecoveryDecision", "recovery", 8, %{
          "task" => ref("task"),
          "disposition" => "retry",
          "interruption" => ref("interrupted"),
          "observationRef" => ref("observation")
        })
      )

    spec =
      hd(fixtures())["spec"]
      |> Map.merge(%{
        "id" => "task-2",
        "earlierTask" => ref("task"),
        "recoveryDecision" => ref("recovery")
      })

    assert {:error, :retry_changed_node} =
             L.apply(s, event("Task", "task-2", 9, Map.put(spec, "node", ref("other"))))

    assert {:error, :retry_reused_task} =
             L.apply(s, event("Task", "task-2", 9, Map.put(spec, "id", "task-1")))

    bad = put_in(s.records["e:observation"]["seq"], 5)
    assert {:error, :reconciliation_required} = L.apply(bad, event("Task", "task-2", 9, spec))
    wrong = put_in(s.records["e:observation"]["spec"]["interruption"], ref("unrelated"))
    assert {:error, :reconciliation_mismatch} = L.apply(wrong, event("Task", "task-2", 9, spec))
    assert {:ok, s} = L.apply(s, event("Task", "task-2", 9, spec))
    gen = %{"bootId" => "boot-2", "runId" => "run-2"}

    prep =
      transition("preparing", 10, "ignored", %{
        "task" => ref("task-2"),
        "priorLifecycle" => nil,
        "sessionBinding" => nil,
        "generation" => gen
      })

    {:ok, s} = L.apply(s, prep)

    binding =
      Enum.at(fixtures(), 2)["spec"] |> Map.merge(%{"task" => ref("task-2"), "generation" => gen})

    {:ok, s} = L.apply(s, event("SessionBinding", "binding-2", 11, binding, "session-key"))

    ready =
      transition("ready", 12, "preparing", %{
        "task" => ref("task-2"),
        "sessionBinding" => ref("binding-2"),
        "generation" => gen
      })

    ready = Map.put(ready, "eventRef", ref("ready-2"))
    assert {:error, :retry_reused_session} = L.apply(s, ready)
    binding = Map.merge(binding, %{"sessionKey" => "new-key", "agentSession" => ref("new-span")})
    {:ok, s} = L.apply(s, event("SessionBinding", "binding-3", 12, binding, "new-key"))

    assert {:ok, s} =
             L.apply(
               s,
               put_in(%{ready | "seq" => 13}, ["spec", "sessionBinding"], ref("binding-3"))
             )

    assert s.attempts["e:task"].status == "interrupted"
    assert s.attempts["e:task-2"].status == "ready"
  end

  test "review and acceptance are separate, exact-version facts and withdrawal blocks reuse" do
    {:ok, s} = through(9)
    lesson = Enum.at(fixtures(), 5)["spec"] |> Map.put("type", "lesson")
    {:ok, s} = L.apply(s, event("Artifact", "lesson", 10, lesson, "session-key"))

    {:ok, s} =
      L.apply(
        s,
        event("Task", "review-task", 11, %{
          "id" => "review-task",
          "step" => "lesson_review",
          "target" => ref("lesson")
        })
      )

    assert D.artifact(s, ref("lesson")) == "review_pending"
    refute D.lesson_eligible?(s, ref("lesson"))

    binding =
      Enum.at(fixtures(), 2)["spec"]
      |> Map.merge(%{
        "provider" => "codex",
        "sessionKey" => "review-key",
        "agentSession" => ref("review-span")
      })

    {:ok, s} = L.apply(s, event("SessionBinding", "review-binding", 12, binding, "review-key"))

    findings = %{
      "type" => "review_findings",
      "sessionBinding" => ref("review-binding"),
      "completeness" => "complete",
      "content" => ref("findings-bytes")
    }

    {:ok, s} = L.apply(s, event("Artifact", "findings", 13, findings, "review-key"))

    {:ok, s} =
      L.apply(
        s,
        event(
          "Review",
          "review",
          14,
          %{
            "target" => ref("lesson"),
            "sessionBinding" => ref("review-binding"),
            "findings" => ref("findings"),
            "recommendation" => "accept"
          },
          "review-key"
        )
      )

    assert D.artifact(s, ref("lesson")) == "reviewed"
    refute D.lesson_eligible?(s, ref("lesson"))

    {:ok, s} =
      L.apply(
        s,
        event(
          "Decision",
          "decision",
          15,
          %{"target" => ref("lesson"), "review" => ref("review"), "disposition" => "accept"},
          "operator"
        )
      )

    assert D.lesson_eligible?(s, ref("lesson"))

    for {disposition, status} <- [
          {"revise", "revision_requested"},
          {"decline", "declined"},
          {"escalate", "escalated"}
        ] do
      {:ok, variant} =
        L.apply(
          s,
          event(
            "Decision",
            "alternative",
            16,
            %{"target" => ref("lesson"), "review" => ref("review"), "disposition" => disposition},
            "operator"
          )
        )

      assert D.artifact(variant, ref("lesson")) == status
      refute D.lesson_eligible?(variant, ref("lesson"))
    end

    {:ok, s} =
      L.apply(
        s,
        event(
          "Artifact",
          "lesson-v2",
          16,
          Map.put(lesson, "earlierArtifact", ref("lesson")),
          "session-key"
        )
      )

    refute D.lesson_eligible?(s, ref("lesson-v2"))

    {:ok, s} =
      L.apply(
        s,
        event(
          "LessonWithdrawal",
          "withdraw",
          17,
          %{"lesson" => ref("lesson"), "priorDecision" => ref("decision")},
          "operator"
        )
      )

    refute D.lesson_eligible?(s, ref("lesson"))
  end

  test "reflection step is finite and failed attempts remain honestly incomplete" do
    rows = fixtures() |> List.update_at(0, &put_in(&1, ["spec", "step"], "reflect"))
    rows = List.update_at(rows, 8, &put_in(&1, ["spec", "outputs"], [ref("reflection")]))
    assert {:ok, state} = L.replay(rows)
    assert state.attempts["e:task"].status == "completed"
    {:ok, state} = through(7)
    {:ok, state} = L.apply(state, transition("failed", 8, "reflecting"))
    assert D.reflection(state, ref("task")) == "pending"

    {:ok, state} =
      L.apply(
        state,
        event(
          "RecoveryDecision",
          "ack",
          9,
          %{"task" => ref("task"), "disposition" => "finalize_incomplete"},
          "operator"
        )
      )

    assert D.reflection(state, ref("task")) == "unavailable_acknowledged"
    assert state.attempts["e:task"].status == "failed"
  end

  test "same-provider review never advances acceptance" do
    {:ok, state} = through(9)

    binding =
      Enum.at(fixtures(), 2)["spec"]
      |> Map.merge(%{"sessionKey" => "other-key", "agentSession" => ref("other-span")})

    {:ok, state} =
      L.apply(state, event("SessionBinding", "other-binding", 10, binding, "other-key"))

    {:ok, state} =
      L.apply(
        state,
        event(
          "Review",
          "bad-review",
          11,
          %{
            "target" => ref("work"),
            "sessionBinding" => ref("other-binding"),
            "recommendation" => "accept"
          },
          "other-key"
        )
      )

    {:ok, state} =
      L.apply(
        state,
        event(
          "Decision",
          "bad-decision",
          12,
          %{"target" => ref("work"), "review" => ref("bad-review"), "disposition" => "accept"},
          "operator"
        )
      )

    assert D.artifact(state, ref("work")) == "produced"
  end

  test "runtime action closes on observed result and assessment without model reflection" do
    rows =
      fixtures()
      |> Enum.take(7)
      |> List.update_at(0, &put_in(&1, ["spec", "step"], "act"))
      |> List.update_at(2, &put_in(&1, ["spec", "actorType"], "runtime_action"))

    {:ok, state} = L.replay(rows)
    assert {:error, :operational_assessment_required} = L.apply(state, List.last(fixtures()))
    {:ok, state} = L.apply(state, event("ToolCall", "tool", 8, %{}))

    result = %{
      "sessionBinding" => ref("binding"),
      "toolCall" => ref("tool"),
      "outcome" => "succeeded",
      "assessment" => ref("assessment")
    }

    {:ok, state} = L.apply(state, event("ActionResult", "result", 9, result))

    assert {:ok, state} =
             L.apply(
               state,
               transition("completed", 10, "reflecting", %{"outputs" => [ref("result")]})
             )

    assert state.attempts["e:task"].status == "completed"
    assert D.reflection(state, ref("task")) == "pending"
  end
end
