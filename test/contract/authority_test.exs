defmodule R5eRecurse.AuthorityTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Authority
  alias R5eRecurse.Authority.Kinds

  defp options do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519)

    [
      subject_public_key: public,
      role: :producer,
      task_id: "reserved-1",
      node_ref: "r5e:node-1",
      task_ref: "event:task-1",
      not_before: "2026-01-01T00:00:00Z",
      not_after: "2027-01-01T00:00:00Z"
    ]
  end

  test "role Kind lists are exact and runtime/model/decision grants remain separate" do
    for role <- [:producer, :reviewer, :delegated_decision, :runtime_action] do
      assert {:ok, kinds} = Kinds.for_role(role)
      assert kinds == Enum.sort(Enum.uniq(kinds))
      assert Enum.all?(kinds, &Regex.match?(~r/\A[a-z0-9.-]+\/v[0-9a-z]+\/[A-Za-z0-9]+\z/, &1))
    end

    {:ok, producer} = Kinds.for_role(:producer)
    {:ok, reviewer} = Kinds.for_role(:reviewer)
    {:ok, delegate} = Kinds.for_role(:delegated_decision)
    {:ok, runtime} = Kinds.for_role(:runtime_action)
    assert reviewer -- producer == ["recurse.r5e.io/v1alpha1/Review"]
    assert delegate -- reviewer == ["recurse.r5e.io/v1alpha1/Decision"]
    assert length(runtime) == 5
    refute "gateway.r5e.io/v1alpha1/LlmCall" in runtime
    assert Kinds.task_creation() == ["recurse.r5e.io/v1alpha1/Task"]
    assert {:error, :unknown_role} = Kinds.for_role(:operator)
  end

  test "task and session candidates record distinct subjects/scopes and preserve parent" do
    opts = options() ++ [operator_badge: "event:operator-badge"]
    assert {:ok, creation} = Authority.task_creation(opts)
    assert creation.candidate.spec["scope"] == %{"taskId" => "reserved-1", "node" => "r5e:node-1"}
    assert creation.candidate.spec["parent"] == %{"$ref" => "event:operator-badge"}
    assert creation.authority == ["event:operator-badge"]
    assert creation.scope_enforcement == :requires_deployment_policy
    assert {:ok, session} = Authority.session_endorsement(opts)
    assert session.candidate.spec["scope"] == %{"task" => "event:task-1"}
    assert session.candidate.spec["mayIssue"] == false
    assert {:ok, badge} = Authority.deployment_badge(opts)
    assert badge.required_signers == [:issuer, :subject]
    assert badge.candidate.spec["subjectKind"] == "agent"
    assert {:ok, runtime} = Authority.deployment_badge(Keyword.put(opts, :role, :runtime_action))
    assert runtime.candidate.spec["subjectKind"] == "service"
  end

  test "scope predicates refuse wrong node/task and malformed shape" do
    scope = %{"taskId" => "t", "node" => "n"}
    facts = %{kind: "recurse.r5e.io/v1alpha1/Task", task_id: "t", node_ref: "n"}
    assert Authority.scope_allows?(scope, facts)
    refute Authority.scope_allows?(scope, %{facts | node_ref: "elsewhere"})
    refute Authority.scope_allows?(scope, %{facts | task_id: "elsewhere"})
    refute Authority.scope_allows?(scope, %{facts | kind: "gateway.r5e.io/v1alpha1/LlmCall"})
    refute Authority.scope_allows?(%{"task" => "a"}, %{task_ref: "b"})
    refute Authority.scope_allows?(%{}, %{})
    refute Authority.scope_allows?(%{"task" => "a", "extra" => "ignored"}, %{task_ref: "a"})
  end

  test "Badge envelope has verified issuer then subject signatures over identical PAE" do
    signer = fn ->
      {public, secret} = :crypto.generate_key(:eddsa, :ed25519)

      %{
        public_key: public,
        sign: fn pae -> {:ok, :crypto.sign(:eddsa, :none, pae, [secret, :ed25519])} end
      }
    end

    issuer = signer.()
    subject = signer.()

    {:ok, plan} =
      Authority.deployment_badge(Keyword.put(options(), :subject_public_key, subject.public_key))

    request = %{
      "origin" => "test",
      "actor" => RecurseVerify.DSSE.key_id!("ed25519", issuer.public_key),
      "target" => %{"group" => "core.r5e.io", "version" => "v1", "kind" => "Badge", "name" => nil},
      "specAddress" => RecurseVerify.Canonical.hash(plan.candidate.spec),
      "derivedFrom" => [],
      "authority" => [],
      "nonce" => "nonce",
      "expires" => "2026-09-22T00:00:00Z"
    }

    assert {:ok, envelope} = Authority.envelope(plan, request, issuer, subject)

    assert Enum.map(envelope["signatures"], & &1["keyid"]) == [
             request["actor"],
             plan.candidate.spec["subject"]
           ]

    assert {:error, _} = Authority.envelope(plan, request, issuer, signer.())

    assert {:error, _} =
             Authority.envelope(plan, Map.put(request, "specAddress", "forged"), issuer, subject)

    assert {:error, _} =
             Authority.envelope(plan, request, issuer, %{
               subject
               | sign: fn _ -> {:ok, <<0::512>>} end
             })
  end
end
