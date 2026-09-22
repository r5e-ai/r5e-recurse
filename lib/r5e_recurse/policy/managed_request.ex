defmodule R5eRecurse.Policy.ManagedRequest do
  @moduledoc "Immutable admission relationships, without body hydration or inventory coverage claims."
  @compile {:no_warn_undefined, [R5e.Policy.Facts, R5e.Canonical]}
  alias R5e.Policy.Facts
  alias R5eRecurse.HarnessInputs
  @local "recurse.r5e.io/v1alpha1/"
  @gateway "gateway.r5e.io/v1alpha1/"

  def valid?(%{kind: "ManagedRequest", spec: spec} = request, facts) do
    actor = facts.actor["id"]

    with true <-
           HarnessInputs.valid?(spec["harnessInputs"], get_in(spec, ["firstInput", "fieldPath"])),
         {:ok, binding} <- event(spec["sessionBinding"], @local <> "SessionBinding"),
         b = binding.payload["spec"],
         true <- actor == b["sessionKey"] and actor == binding.payload["actor"]["id"],
         authority = [b["badge"]["$ref"], b["delegation"]["$ref"]],
         true <-
           length(Enum.uniq(authority)) == 2 and
             Enum.sort(request.authority_refs) == Enum.sort(authority),
         true <- Enum.sort(binding.payload["authority"]) == Enum.sort(authority),
         {:ok, task} <- event(b["task"], @local <> "Task"),
         {:ok, badge} <- event(b["badge"], "core.r5e.io/v1/Badge"),
         {:ok, delegation} <- event(b["delegation"], "core.r5e.io/v1/Endorsement"),
         true <-
           badge.payload["spec"]["subject"] == actor and
             delegation.payload["spec"]["subject"] == actor,
         true <- delegation.payload["actor"]["id"] == task.payload["spec"]["delegatedBy"],
         true <-
           Enum.all?(
             [badge, delegation],
             &R5eRecurse.Authority.scope_allows?(&1.payload["spec"]["scope"], %{
               task_ref: b["task"]["$ref"]
             })
           ),
         {:ok, span} <- event(b["agentSessionAdmission"], @gateway <> "AgentSession"),
         true <- span.payload["actor"]["id"] == actor,
         true <-
           b["agentSession"] == %{
             "$ref" => @gateway <> "AgentSession/" <> span_name(span)
           },
         {:ok, call} <- event(spec["llmCall"], @gateway <> "LlmCall"),
         true <- call.event["seq"] > binding.event["seq"],
         true <- call.payload["actor"]["id"] == actor,
         true <- Enum.sort(call.payload["authority"]) == Enum.sort(authority),
         true <- call.payload["spec"]["session"] == b["agentSession"],
         true <- call.payload["spec"]["model"] == b["model"],
         {:ok, call_span} <- resolved(call, "/session", @gateway <> "AgentSession"),
         true <- call_span.event == span.event,
         {:ok, prompt} <- resolved(call, "/prompt", @gateway <> "Prompt"),
         {:ok, prompt_span} <- resolved(prompt, "/session", @gateway <> "AgentSession"),
         true <- prompt_span.event == span.event,
         true <-
           prompt.payload["actor"]["id"] == actor and
             prompt.payload["spec"]["session"] == b["agentSession"],
         true <- prompt.event["seq"] < call.event["seq"],
         true <- Enum.sort(prompt.payload["authority"]) == Enum.sort(authority),
         true <- prompt.payload["spec"]["contentRef"] == spec["inboundBody"],
         true <- HarnessInputs.digest?(spec["bodyDigest"]),
         true <- spec["inboundBody"] == %{"$ref" => "bytes:" <> spec["bodyDigest"]},
         true <- spec["outboundBody"] == spec["inboundBody"],
         {:ok, manifest} <- event(b["contextManifest"], @local <> "ContextManifest") do
      # Facts.event serves only already-recorded events: call admission precedes
      # this candidate's eventual append without querying a speculative position.
      Enum.all?(
        spec["harnessInputs"],
        &provenance?(&1, spec["sessionBinding"], b, manifest, actor)
      )
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_, _), do: true

  defp provenance?(item, binding_ref, binding, manifest, actor) do
    case event(item["provenance"], [@local <> "ContextManifest", @local <> "Artifact"]) do
      {:ok, %{payload: %{"target" => %{"kind" => "ContextManifest"}}}} ->
        item["provenance"] == binding["contextManifest"] and
          Enum.any?(
            manifest.payload["spec"]["harnessConfiguration"],
            &(&1["digest"] == item["digest"])
          )

      {:ok, %{payload: payload}} ->
        spec = payload["spec"]

        payload["actor"]["id"] == actor and spec["sessionBinding"] == binding_ref and
          spec["type"] == "trace" and spec["completeness"] == "complete" and
          spec["content"] == %{"$ref" => "bytes:" <> item["digest"]}

      _ ->
        false
    end
  end

  defp resolved(record, path, kind) do
    with [entry] <-
           Enum.filter(
             record.payload["resolvedRefs"],
             &(&1["path"] == path and &1["class"] == "kind")
           ),
         {:ok, resolved} <- event(%{"$ref" => entry["admissionEvent"]}, kind),
         true <- entry["value"] == kind <> "/" <> resource_name(kind, resolved),
         true <- entry["value"] == record.payload["spec"][String.trim_leading(path, "/")]["$ref"],
         true <- entry["specAddress"] == R5e.Canonical.hash(resolved.payload["spec"]),
         true <- entry["generation"] == resolved.event["seq"],
         true <- resolved.event["seq"] < record.event["seq"] do
      {:ok, resolved}
    else
      _ -> :error
    end
  end

  defp span_name(record), do: record.payload["target"]["name"] || "event:" <> record.event["hash"]
  defp resource_name(@gateway <> "AgentSession", record), do: span_name(record)
  defp resource_name(_, record), do: record.payload["target"]["name"]

  defp event(%{"$ref" => ref}, kinds) do
    with {:ok,
          %{
            event: %{"kind" => "admission.granted"},
            payload: %{"outcome" => "admitted", "identity" => "signed"}
          } = record} <-
           Facts.event(ref),
         target = record.payload["target"],
         true <-
           Enum.join([target["group"], target["version"], target["kind"]], "/") in List.wrap(
             kinds
           ) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  defp event(_, _), do: :error
end
