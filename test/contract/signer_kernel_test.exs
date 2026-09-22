defmodule R5eRecurse.SignerKernelTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{Authority, KernelClient, SessionKeys, Signer, Signer.Snapshot, Signer.Channel}
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
    prompt_kind = File.read!("test/fixtures/gateway/prompt.json") |> Jason.decode!()

    assert {:ok, _} =
             Fixture.admit("core.r5e.io", "v1", "KindDefinition", nil, prompt_kind, :node, [])

    call_kind = File.read!("test/fixtures/gateway/llm-call.json") |> Jason.decode!()

    assert {:ok, _} =
             Fixture.admit("core.r5e.io", "v1", "KindDefinition", nil, call_kind, :node, [])

    policy_kind = File.read!("test/fixtures/gateway/policy-bundle.json") |> Jason.decode!()

    assert {:ok, _} =
             Fixture.admit("core.r5e.io", "v1", "KindDefinition", nil, policy_kind, :node, [])

    {:ok, ctx}
  end

  test "real Channel signs Prompt, LlmCall and ManagedRequest; parent revocation fences the next operation",
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

    engine_bytes = Recurse.Fold.Policy.EngineBuild.bytes()

    assert {:ok, _, engine_address, _} =
             R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), engine_bytes, "application/json")

    Recurse.Fold.Policy.EngineBuild.cache_address(engine_address)
    policy_paths = ["gateway.r5e.io/v1alpha1/PolicyBundle", "gateway.r5e.io/v1alpha1/LlmCall"]
    policy_badge = Fixture.credential("Badge", :node, ctx.operator, policy_paths, nil, [])
    policy_grant = Fixture.credential("Endorsement", :node, ctx.operator, policy_paths, nil, [])

    policy_source =
      "permit(principal == Recurse::Principal::ServiceAccount::\"#{actor}\", action, resource);"

    assert {:ok, _, policy_address, _} =
             R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), policy_source, "text/plain")

    assert {:ok, _} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "PolicyBundle",
               "active",
               %{
                 "engine" => "cedar",
                 "sourceRef" => %{"$ref" => policy_address},
                 "governs" => ["gateway.r5e.io/v1alpha1/LlmCall"]
               },
               ctx.operator,
               [policy_badge["eventRef"], policy_grant["eventRef"]]
             )

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

    binding_spec =
      Map.merge(ctx.binding, %{
        "agentSession" => %{"$ref" => span_ref},
        "agentSessionAdmission" => %{"$ref" => span["eventRef"]},
        "sessionKey" => actor,
        "generation" => key.generation,
        "badge" => %{"$ref" => badge["eventRef"]},
        "delegation" => %{"$ref" => delegation["eventRef"]},
        "role" => "producer"
      })

    binding_target = %{
      "group" => "recurse.r5e.io",
      "version" => "v1alpha1",
      "kind" => "SessionBinding",
      "name" => nil
    }

    binding_envelope = session_envelope(keys, key, binding_target, binding_spec, refs)

    assert {:ok, binding} =
             R5e.Admission.admit(%{
               group: "recurse.r5e.io",
               version: "v1alpha1",
               kind: "SessionBinding",
               name: nil,
               spec: binding_spec,
               envelope: binding_envelope
             })

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

    directory =
      Path.join(System.tmp_dir!(), "kernel-signer-channel-#{System.unique_integer([:positive])}")

    channel =
      start_supervised!(
        {Channel, keys: keys, directory: directory, handler: Signer.channel_handler(signer)}
      )

    provision = Channel.provision(channel)
    {:ok, slot} = Signer.register(signer, self(), key.generation, "request-1", context)
    wire = %{"kind" => @prompt, "specBytes" => Canonical.encode(spec), "authority" => refs}
    assert %{"ok" => envelope} = channel_sign(channel, provision, key.generation, slot, wire)
    assert_receive {:covered_head, first_head}
    assert first_head == before.head.seq
    assert {:ok, prompt_request, ^actor} = DSSE.verify(envelope, key.public_key)
    assert Jason.decode!(prompt_request)["authority"] == refs
    assert {:ok, receipt} = KernelClient.submit(client, target, envelope, spec)
    assert {:ok, after_prompt} = Snapshot.read(client, origin)

    assert {:ok, %{actor: ^actor, spec: ^spec}} =
             Snapshot.record(after_prompt, receipt["eventRef"])

    assert {:error, :operation_consumed} = Signer.sign(signer, slot, wire)

    # Real closed gateway schema, with gatewayContext deliberately omitted:
    # this exercises signer/transport/admission, not managed gateway forwarding.
    call_kind = "gateway.r5e.io/v1alpha1/LlmCall"
    call_target = %{target | "kind" => "LlmCall"}

    routing = %{
      "provider" => "provider",
      "transport" => "https",
      "requestPath" => "/v1/responses",
      "apiFormat" => "responses"
    }

    call_spec =
      Map.merge(routing, %{
        "model" => "model",
        "upstreamHost" => "provider.example",
        "session" => %{"$ref" => span_ref},
        "prompt" => %{"$ref" => "gateway.r5e.io/v1alpha1/Prompt/" <> receipt["name"]}
      })

    read_record = fn ref ->
      with {:ok, view} <- Snapshot.read(client, origin), do: Snapshot.record(view, ref, actor)
    end

    call_context = %{
      context
      | request:
          Map.merge(context.request, %{
            targets: %{call_kind => call_target},
            model: "model",
            upstream_host: "provider.example",
            call_routing: routing,
            read_record: read_record
          }),
        authority: %{context.authority | kind: call_kind}
    }

    {:ok, call_slot} = Signer.register(signer, self(), key.generation, "request-1", call_context)

    call_wire = %{
      "kind" => call_kind,
      "specBytes" => Canonical.encode(call_spec),
      "authority" => refs
    }

    assert %{"ok" => call_envelope} =
             channel_sign(channel, provision, key.generation, call_slot, call_wire)

    assert_receive {:covered_head, _}
    assert {:ok, call_request, ^actor} = DSSE.verify(call_envelope, key.public_key)
    assert Jason.decode!(call_request)["authority"] == refs

    assert {:ok, call_receipt} =
             KernelClient.submit(client, call_target, call_envelope, call_spec)

    assert {:error, :operation_consumed} = Signer.sign(signer, call_slot, call_wire)

    managed_kind = "recurse.r5e.io/v1alpha1/ManagedRequest"
    managed_target = %{target | "group" => "recurse.r5e.io", "kind" => "ManagedRequest"}
    # Manual exact candidate: the separate ManagedRequest builder is not tested here.
    managed_spec = %{
      "sessionBinding" => %{"$ref" => binding["eventRef"]},
      "llmCall" => %{"$ref" => call_receipt["eventRef"]},
      "inboundBody" => %{"$ref" => address},
      "outboundBody" => %{"$ref" => address},
      "bodyDigest" => Canonical.hash_bytes(body),
      "firstInput" => %{
        "fieldPath" => "/messages/0/content",
        "digest" => Canonical.hash_bytes("exact body")
      },
      "method" => "POST",
      "path" => "/v1/responses",
      "upstream" => "provider.example",
      "transport" => "https",
      "semanticHeaders" => [],
      "operationId" => "request-1"
    }

    managed_context = %{
      call_context
      | request:
          Map.merge(call_context.request, %{
            targets: %{managed_kind => managed_target},
            session_binding: binding["eventRef"],
            llm_call: call_receipt["eventRef"],
            managed: managed_spec
          }),
        authority: %{context.authority | kind: managed_kind}
    }

    {:ok, managed_slot} =
      Signer.register(signer, self(), key.generation, "request-1", managed_context)

    managed_wire = %{
      "kind" => managed_kind,
      "specBytes" => Canonical.encode(managed_spec),
      "authority" => refs
    }

    assert %{"ok" => managed_envelope} =
             channel_sign(channel, provision, key.generation, managed_slot, managed_wire)

    assert_receive {:covered_head, _}
    assert {:ok, managed_request, ^actor} = DSSE.verify(managed_envelope, key.public_key)
    assert Jason.decode!(managed_request)["authority"] == refs

    assert {:ok, managed_receipt} =
             KernelClient.submit(client, managed_target, managed_envelope, managed_spec)

    assert {:error, :operation_consumed} = Signer.sign(signer, managed_slot, managed_wire)
    assert {:ok, final_view} = Snapshot.read(client, origin)

    for {event, expected} <- [
          {receipt, spec},
          {call_receipt, call_spec},
          {managed_receipt, managed_spec}
        ] do
      assert {:ok, %{actor: ^actor, spec: ^expected}} =
               Snapshot.record(final_view, event["eventRef"])
    end

    assert {:ok, ^body} = KernelClient.get_cas(client, address)

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

  defp channel_sign(channel, provision, generation, slot, request) do
    {:ok, route} = Channel.register(channel, self(), generation, %{slot: slot})

    message = %{
      "secret" => provision.secret,
      "route" => route.route,
      "credential" => route.credential,
      "generation" => generation,
      "operation" => "authenticate",
      "request" => %{}
    }

    assert %{"ok" => true} = channel_wire(provision.path, message)
    channel_wire(provision.path, %{message | "operation" => "sign", "request" => request})
  end

  defp channel_wire(path, message) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false, packet: 4])

    :ok = :gen_tcp.send(socket, Jason.encode!(message))
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
    Jason.decode!(bytes)
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
