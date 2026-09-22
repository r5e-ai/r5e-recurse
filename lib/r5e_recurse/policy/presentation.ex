defmodule R5eRecurse.Policy.Presentation do
  @moduledoc "Validated facts presented to the admitted narrowing policy."
  @compile {:no_warn_undefined, [R5e.Policy.Facts, R5e.Canonical]}
  alias R5e.Policy.Facts
  @group "recurse.r5e.io"
  @labels %{
    "custody" => "runtime-held",
    "profile" => "cooperative-local",
    "signerReachability" => "same-user-cooperative-limit"
  }

  def present(request) do
    with {:ok, facts} <- Facts.resolve(request),
         true <- is_map(request[:spec]) and is_list(request[:authority_refs]),
         {:ok, labels} <- labels(request),
         {:ok, binding} <- binding(request, facts),
         {:ok, task_scope} <- task_scope(request, facts),
         {:ok, acyclic} <- acyclic(request) do
      context = %{
        "target_kind" => request.kind,
        "managed_request_valid" => R5eRecurse.Policy.ManagedRequest.valid?(request, facts),
        "custody" => labels["custody"],
        "profile" => labels["profile"],
        "signer_reachability" => labels["signerReachability"],
        "authority_present" => request.authority_refs != [],
        "binding_valid" => binding.valid,
        "task_scope_valid" => task_scope,
        "binding_signer" => facts.actor["id"],
        "session_key" => binding.session_key,
        "badge_subject" => binding.badge_subject,
        "delegation_subject" => binding.delegation_subject,
        "span_actor" => binding.span_actor,
        "node_acyclic" => acyclic
      }

      actor = facts.actor["id"]
      target = "#{request.group}/#{request.version}/#{request.kind}/#{request[:name] || ""}"

      cedar_request = %{
        "principal" => uid("Recurse::Principal", actor),
        "action" => uid("Recurse::Action", "admit"),
        "resource" => uid("Recurse::Resource", target),
        "context" => context
      }

      entities = [
        %{
          "uid" => %{"type" => "Recurse::Principal", "id" => actor},
          "attrs" => %{},
          "parents" => []
        },
        %{
          "uid" => %{"type" => "Recurse::Resource", "id" => target},
          "attrs" => %{},
          "parents" => []
        }
      ]

      {:ok, R5e.Canonical.encode(cedar_request), R5e.Canonical.encode(entities)}
    else
      {:error, _} = error -> error
      _ -> {:error, "malformed policy request"}
    end
  end

  defp labels(%{kind: kind, spec: spec}) when kind in ["SessionBinding", "ContextManifest"] do
    if Enum.all?(@labels, fn {key, _} -> is_binary(spec[key]) end),
      do: {:ok, Map.take(spec, Map.keys(@labels))},
      else:
        {:error, "required custody, profile or signerReachability label is missing or malformed"}
  end

  defp labels(_), do: {:ok, @labels}

  defp binding(%{kind: "SessionBinding", spec: spec} = request, facts) do
    with {:ok, task_ref} <- ref(spec, "task"),
         {:ok, task} <- admitted(task_ref, "recurse.r5e.io/v1alpha1/Task"),
         {:ok, badge_ref} <- ref(spec, "badge"),
         {:ok, delegation_ref} <- ref(spec, "delegation"),
         {:ok, span_ref} <- ref(spec, "agentSessionAdmission"),
         {:ok, session_ref} <- ref(spec, "agentSession"),
         {:ok, badge} <- admitted(badge_ref, "core.r5e.io/v1/Badge"),
         {:ok, delegation} <- admitted(delegation_ref, "core.r5e.io/v1/Endorsement"),
         {:ok, span} <- admitted(span_ref, "gateway.r5e.io/v1alpha1/AgentSession"),
         {:ok, session} <- Facts.fetch(session_ref),
         true <-
           is_binary(spec["sessionKey"]) and spec["actorType"] in ["agent", "runtime_action"] do
      actor = facts.actor["id"]
      authority = request.authority_refs
      resolved = Enum.map(facts.resolved_authority, & &1["value"])

      provider =
        spec["actorType"] != "agent" or (nonempty?(spec["provider"]) and nonempty?(spec["model"]))

      valid =
        session["actor"] == actor and session["admissionEvent"] == span_ref and
          badge_ref in authority and delegation_ref in authority and badge_ref in resolved and
          delegation_ref in resolved and provider and
          get_in(delegation, ["actor", "id"]) == task["spec"]["delegatedBy"] and
          R5eRecurse.Authority.scope_allows?(delegation["spec"]["scope"], %{task_ref: task_ref}) and
          R5eRecurse.Authority.scope_allows?(badge["spec"]["scope"], %{task_ref: task_ref})

      {:ok,
       %{
         valid: valid,
         session_key: spec["sessionKey"],
         badge_subject: badge["spec"]["subject"],
         delegation_subject: delegation["spec"]["subject"],
         span_actor: get_in(span, ["actor", "id"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "malformed SessionBinding presentation"}
    end
  end

  defp binding(_, _),
    do:
      {:ok,
       %{valid: true, session_key: "", badge_subject: "", delegation_subject: "", span_actor: ""}}

  defp task_scope(%{kind: "Task", spec: spec} = request, facts) do
    with {:ok, delegation_ref} <- ref(spec, "delegationRef"),
         {:ok, node_ref} <- ref(spec, "node"),
         {:ok, delegation} <- admitted(delegation_ref, "core.r5e.io/v1/Endorsement") do
      resolved = Enum.map(facts.resolved_authority, & &1["value"])

      {:ok,
       delegation_ref in request.authority_refs and delegation_ref in resolved and
         delegation["spec"]["subject"] == facts.actor["id"] and
         get_in(delegation, ["actor", "id"]) == spec["delegatedBy"] and
         R5eRecurse.Authority.scope_allows?(delegation["spec"]["scope"], %{
           kind: "recurse.r5e.io/v1alpha1/Task",
           task_id: spec["id"],
           node_ref: node_ref
         })}
    else
      {:error, _} = error -> error
      _ -> {:error, "malformed Task delegation presentation"}
    end
  end

  defp task_scope(_, _), do: {:ok, true}

  defp admitted(ref, expected) do
    with {:ok, %{event: %{"kind" => "admission.granted"}, payload: payload}} <- Facts.event(ref),
         %{"group" => g, "version" => v, "kind" => k} <- payload["target"],
         true <- "#{g}/#{v}/#{k}" == expected do
      {:ok, payload}
    else
      _ -> {:error, "#{ref} is not an admitted #{expected}"}
    end
  end

  defp acyclic(%{kind: "Node", spec: spec} = request) do
    target = if request[:name], do: "#{@group}/#{request.version}/Node/#{request.name}", else: nil
    walk_parent(spec["parent"], MapSet.new(List.wrap(target)), spec["graph"], 0)
  end

  defp acyclic(_), do: {:ok, true}
  defp walk_parent(nil, _, _, _), do: {:ok, true}

  defp walk_parent(_, _, _, depth) when depth >= 256,
    do: {:error, "Node parent walk exceeds 256 links"}

  defp walk_parent(%{"$ref" => ref}, seen, graph, depth) do
    if MapSet.member?(seen, ref) do
      {:ok, false}
    else
      with {:ok, entry} <- Facts.fetch(ref),
           true <- entry["group"] == @group and entry["kind"] == "Node" do
        if entry["spec"]["graph"] == graph,
          do: walk_parent(entry["spec"]["parent"], MapSet.put(seen, ref), graph, depth + 1),
          else: {:ok, false}
      else
        _ -> {:error, "Node parent is missing or malformed"}
      end
    end
  end

  defp walk_parent(_, _, _, _), do: {:error, "Node parent ref is malformed"}

  defp ref(spec, key) do
    case spec[key] do
      %{"$ref" => ref} when is_binary(ref) -> {:ok, ref}
      _ -> {:error, "#{key} ref is missing or malformed"}
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp uid(type, id), do: type <> "::" <> Jason.encode!(id)
end
