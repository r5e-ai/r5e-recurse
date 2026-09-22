defmodule R5eRecurse.AuthorityKernelTest do
  use ExUnit.Case, async: false
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.TestHelpers)
  alias R5eRecurse.Authority

  test "real kernel resolves constructed credentials, intersections, term, revocation and parent chain" do
    R5e.Vectors.with_fresh_kernel(fn ->
      # Narrow synthetic payload schemas isolate the real credential/authentication
      # pipeline. Domain Task/Node scope tests live in delegation_scope_test.
      for path <-
            ~w(gateway.r5e.io/v1alpha1/AgentSession gateway.r5e.io/v1alpha1/LlmCall recurse.r5e.io/v1alpha1/Review recurse.r5e.io/v1alpha1/Decision recurse.r5e.io/v1alpha1/Task) do
        [group, version, kind] = String.split(path, "/")

        definition = %{
          "group" => group,
          "version" => version,
          "kind" => kind,
          "substrate" => "event",
          "naming" => %{"mode" => "content"},
          "schema" => %{"properties" => %{}, "required" => [], "additionalProperties" => false},
          "predicates" => []
        }

        assert {:ok, _} =
                 R5e.TestHelpers.admit_request(%{
                   group: "core.r5e.io",
                   version: "v1",
                   kind: "KindDefinition",
                   spec: definition,
                   keys: [:node]
                 })
      end

      operator = R5e.Vectors.key(501)
      session = R5e.Vectors.key(502)
      other = R5e.Vectors.key(503)
      runtime = R5e.Vectors.key(504)

      opts = [
        subject_public_key: session.public,
        role: :producer,
        task_ref: "event:task",
        task_id: "reserved",
        node_ref: "node:one",
        not_before: "2020-01-01T00:00:00Z",
        not_after: "2035-01-01T00:00:00Z"
      ]

      {:ok, parent_plan} =
        Authority.deployment_badge(Keyword.put(opts, :subject_public_key, operator.public))

      parent_plan =
        update_in(
          parent_plan.candidate.spec,
          &(&1
            |> Map.put("mayIssue", true)
            |> Map.put(
              "kinds",
              [&1["kinds"], "core.r5e.io/v1/Endorsement", "recurse.r5e.io/v1alpha1/Task"]
              |> List.flatten()
            ))
        )

      assert {:ok, parent} = issue(parent_plan, other, operator)

      {:ok, delegation_plan} =
        Authority.session_endorsement(opts ++ [operator_badge: parent["eventRef"]])

      assert {:ok, delegation} = issue(delegation_plan, operator)
      {:ok, badge_plan} = Authority.deployment_badge(Keyword.put(opts, :role, :reviewer))
      assert {:ok, badge} = issue(badge_plan, operator, session)
      refs = [badge["eventRef"], delegation["eventRef"]]
      assert {:ok, receipt} = act("gateway.r5e.io/v1alpha1/AgentSession", session, refs)

      chain =
        Enum.find(receipt["resolvedAuthority"], &(&1["value"] == delegation["eventRef"]))["chain"]

      assert Enum.any?(
               chain,
               &(&1["value"] == parent["eventRef"] and &1["kind"] == "core.r5e.io/v1/Badge")
             )

      assert {:denied, _} =
               act("gateway.r5e.io/v1alpha1/AgentSession", session, [parent["eventRef"]])

      assert {:denied, _} = act("recurse.r5e.io/v1alpha1/Review", session, refs)
      assert {:denied, _} = act("recurse.r5e.io/v1alpha1/Decision", session, refs)

      {:ok, creation_plan} =
        Authority.task_creation(Keyword.put(opts, :subject_public_key, runtime.public))

      assert {:ok, creation} = issue(creation_plan, operator)

      assert {:denied, _} =
               act("gateway.r5e.io/v1alpha1/LlmCall", runtime, [creation["eventRef"]])

      assert {:denied, _} =
               act("recurse.r5e.io/v1alpha1/Decision", runtime, [creation["eventRef"]])

      {:ok, expired_plan} =
        Authority.session_endorsement(Keyword.put(opts, :not_after, "2021-01-01T00:00:00Z"))

      assert {:ok, expired} = issue(expired_plan, operator)

      assert {:denied, _} =
               act("gateway.r5e.io/v1alpha1/AgentSession", session, [expired["eventRef"]])

      assert {:ok, _} =
               R5e.TestHelpers.admit_request(%{
                 group: "core.r5e.io",
                 version: "v1",
                 kind: "Revocation",
                 spec: %{"revokes" => %{"$ref" => delegation["eventRef"]}},
                 keys: [operator]
               })

      assert {:denied, _} = act("gateway.r5e.io/v1alpha1/AgentSession", session, refs)
    end)
  end

  defp issue(plan, issuer, subject \\ nil) do
    target =
      Map.take(plan.candidate, [:group, :version, :kind, :name])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    request =
      R5e.Request.build(%{target: target, spec: plan.candidate.spec, authority: plan.authority},
        actor: R5e.Request.key_id(issuer)
      )

    callback = fn key ->
      %{
        public_key: key.public,
        sign: fn bytes -> {:ok, :crypto.sign(:eddsa, :none, bytes, [key.private, :ed25519])} end
      }
    end

    assert {:ok, envelope} =
             Authority.envelope(
               plan,
               request,
               callback.(issuer),
               if(subject, do: callback.(subject))
             )

    R5e.Admission.admit(Map.put(plan.candidate, :envelope, envelope))
  end

  defp act(path, key, authority) do
    [group, version, kind] = String.split(path, "/")

    R5e.TestHelpers.admit_request(%{
      group: group,
      version: version,
      kind: kind,
      spec: %{},
      keys: [key],
      authority: authority
    })
  end
end
