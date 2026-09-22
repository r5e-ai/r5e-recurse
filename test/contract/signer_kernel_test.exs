defmodule R5eRecurse.SignerKernelTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{Authority, KernelClient, SessionKeys, Signer, Signer.Snapshot}
  alias R5eRecurse.PolicyBaseTest, as: Fixture
  alias RecurseVerify.{Canonical, DSSE}
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)
  @compile {:no_warn_undefined,
            [
              R5e.Admission,
              R5e.DSSE,
              R5e.Origin,
              R5e.Request,
              R5e.HTTP.Router,
              R5e.TestHelpers,
              R5e.Log
            ]}
  @prompt "gateway.r5e.io/v1alpha1/Prompt"

  setup do
    session_kind = File.read!("test/fixtures/gateway/agent-session.json") |> Jason.decode!()
    {:ok, ctx} = Fixture.setup_fixture(session_kind)
    # This Kind is absent from Fixture, so install the actual closed definition;
    # no existing Kind/schema or shared fixture function is replaced.
    prompt_kind = File.read!("/fold/apps/recurse_fold/priv/kinds/prompt.json") |> Jason.decode!()

    assert {:ok, _} =
             Fixture.admit("core.r5e.io", "v1", "KindDefinition", nil, prompt_kind, :node, [])

    {:ok, ctx}
  end

  test "fresh real credential history authorizes a session Prompt and parent revocation stops the next signature",
       ctx do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "live-signer", self())
    actor = DSSE.key_id!("ed25519", key.public_key)
    {:ok, role_kinds} = Authority.Kinds.for_role(:producer)

    parent =
      Fixture.credential(
        "Badge",
        :node,
        ctx.operator,
        Enum.uniq(ctx.paths ++ role_kinds),
        nil,
        []
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    common = [
      subject_public_key: key.public_key,
      role: :producer,
      task_ref: ctx.task["eventRef"],
      not_before: DateTime.to_iso8601(DateTime.add(now, -60, :second)),
      not_after: DateTime.to_iso8601(DateTime.add(now, 3600, :second)),
      operator_badge: parent["eventRef"]
    ]

    {:ok, badge_plan} = Authority.deployment_badge(common)
    {:ok, delegation_plan} = Authority.session_endorsement(common)
    badge = issue(ctx.operator, badge_plan, keys, key)
    delegation = issue(ctx.operator, delegation_plan, keys, key)
    refs = [badge["eventRef"], delegation["eventRef"]]

    # Bootstrap span uses the actual ephemeral key before it is signer-guarded.
    span_target = %{
      "group" => "gateway.r5e.io",
      "version" => "v1alpha1",
      "kind" => "AgentSession",
      "name" => nil
    }

    span_spec = %{"harness" => "signer-kernel-test"}
    span_envelope = session_envelope(keys, key, span_target, span_spec, refs)

    assert {:ok, span} =
             R5e.Admission.admit(%{
               group: "gateway.r5e.io",
               version: "v1alpha1",
               kind: "AgentSession",
               name: nil,
               spec: span_spec,
               envelope: span_envelope
             })

    span_ref = "gateway.r5e.io/v1alpha1/AgentSession/" <> span["name"]
    body = " {\"messages\":[{\"content\":\"exact body\"}],\"temperature\":0.5} "

    assert {:ok, _, address, _} =
             R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), body, "application/json")

    assert address == "bytes:" <> Canonical.hash_bytes(body)

    http = start_supervised!({Bandit, plug: R5e.HTTP.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(http)
    client = KernelClient.new("http://127.0.0.1:#{port}")
    origin = R5e.Origin.current()
    assert {:ok, before} = Snapshot.read(client, origin)

    assert {:ok, credential_result} =
             R5eRecurse.Signer.Authority.validate(before, %{
               actor: actor,
               role: :producer,
               kind: @prompt,
               task: ctx.task["eventRef"],
               origin: origin,
               refs: %{badge: badge["eventRef"], delegation: delegation["eventRef"]},
               authority: refs,
               roots: %{badge: R5e.DSSE.node_key_id(), delegation: R5e.DSSE.node_key_id()},
               now: DateTime.utc_now(),
               max_snapshot_age_seconds: 10
             })

    assert credential_result.authority == refs

    target = %{
      "group" => "gateway.r5e.io",
      "version" => "v1alpha1",
      "kind" => "Prompt",
      "name" => nil
    }

    spec = %{
      "contentRef" => %{"$ref" => address},
      "session" => %{"$ref" => span_ref},
      "mediaType" => "application/json",
      "role" => "user"
    }

    context = %{
      request: %{
        actor: actor,
        role: :producer,
        authority: refs,
        targets: %{@prompt => target},
        span: span_ref,
        body: body,
        read_bytes: &KernelClient.get_cas(client, &1)
      },
      authority: %{
        actor: actor,
        role: :producer,
        kind: @prompt,
        task: ctx.task["eventRef"],
        origin: origin,
        refs: %{badge: badge["eventRef"], delegation: delegation["eventRef"]},
        authority: refs,
        roots: %{badge: R5e.DSSE.node_key_id(), delegation: R5e.DSSE.node_key_id()},
        max_snapshot_age_seconds: 10
      }
    }

    observer = self()

    snapshot = fn _ ->
      result = Snapshot.read(client, origin)
      if match?({:ok, _}, result), do: send(observer, {:covered_head, elem(result, 1).head.seq})
      result
    end

    signer = start_supervised!({Signer, keys: keys, snapshot: snapshot})
    {:ok, slot} = Signer.register(signer, self(), key.generation, "request-1", context)
    wire = %{"kind" => @prompt, "specBytes" => Canonical.encode(spec), "authority" => refs}
    assert {:ok, envelope} = Signer.sign(signer, slot, wire)
    assert_receive {:covered_head, first_head}
    assert first_head == before.head.seq
    assert {:ok, _request, ^actor} = DSSE.verify(envelope, key.public_key)
    assert {:ok, receipt} = KernelClient.submit(client, target, envelope, spec)
    assert {:ok, after_prompt} = Snapshot.read(client, origin)

    assert {:ok, %{actor: ^actor, spec: ^spec}} =
             Snapshot.record(after_prompt, receipt["eventRef"])

    assert {:error, :operation_consumed} = Signer.sign(signer, slot, wire)

    # Revoke the actual issuer parent, not only a leaf in a synthetic index.
    assert {:ok, revocation} =
             R5e.TestHelpers.admit_request(%{
               group: "core.r5e.io",
               version: "v1",
               kind: "Revocation",
               spec: %{"revokes" => %{"$ref" => parent["eventRef"]}},
               keys: [:node]
             })

    {:ok, next_slot} = Signer.register(signer, self(), key.generation, "request-2", context)
    assert {:error, :signer_refused} = Signer.sign(signer, next_slot, wire)
    assert_receive {:covered_head, next_head}
    assert next_head >= revocation["seq"] and next_head > first_head
    assert {:error, :operation_consumed} = Signer.sign(signer, next_slot, wire)
    assert length(R5e.Log.events()) == next_head
  end

  defp issue(operator, plan, keys, key) do
    target =
      Map.take(plan.candidate, [:group, :version, :kind, :name])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    request =
      R5e.Request.build(%{target: target, spec: plan.candidate.spec, authority: plan.authority},
        actor: R5e.Request.key_id(operator)
      )

    issuer = %{
      public_key: operator.public,
      sign: fn pae -> {:ok, :crypto.sign(:eddsa, :none, pae, [operator.private, :ed25519])} end
    }

    subject = %{public_key: key.public_key, sign: &SessionKeys.sign(keys, key.generation, &1)}
    assert {:ok, envelope} = Authority.envelope(plan, request, issuer, subject)
    assert {:ok, receipt} = R5e.Admission.admit(Map.put(plan.candidate, :envelope, envelope))
    receipt
  end

  defp session_envelope(keys, key, target, spec, authority) do
    actor = DSSE.key_id!("ed25519", key.public_key)
    request = R5e.Request.build(%{target: target, spec: spec, authority: authority}, actor: actor)
    type = "application/vnd.r5e.admission-request+json;v=1"
    bytes = Canonical.encode(request)
    {:ok, signature} = SessionKeys.sign(keys, key.generation, DSSE.pae(type, bytes))

    %{
      "payloadType" => type,
      "payload" => Base.encode64(bytes),
      "signatures" => [%{"keyid" => actor, "sig" => Base.encode64(signature)}],
      "publicKeys" => [
        %{"keyid" => actor, "algorithm" => "ed25519", "bytes" => Base.encode64(key.public_key)}
      ]
    }
  end
end
