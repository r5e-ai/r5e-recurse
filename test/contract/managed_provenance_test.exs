defmodule R5eRecurse.ManagedProvenanceTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.PolicyBaseTest, as: Fixture
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)
  @compile {:no_warn_undefined,
            [R5e.Request, R5e.TestHelpers, R5e.DSSE, R5e.Policy.Facts, R5e.Canonical]}
  @local "recurse.r5e.io"

  setup do
    {:ok, ctx} = Fixture.setup_fixture()

    for file <- ~w(prompt llm-call) do
      definition = File.read!("test/fixtures/gateway/#{file}.json") |> Jason.decode!()

      assert {:ok, _} =
               Fixture.admit("core.r5e.io", "v1", "KindDefinition", nil, definition, :node, [])
    end

    paths = ctx.paths ++ ~w(gateway.r5e.io/v1alpha1/Prompt gateway.r5e.io/v1alpha1/LlmCall)
    scope = %{"task" => ctx.task["eventRef"]}
    badge = Fixture.credential("Badge", :node, ctx.session, paths, nil, [], scope)
    parent = Fixture.credential("Badge", :node, ctx.operator, paths, nil, [])

    delegation =
      Fixture.credential(
        "Endorsement",
        ctx.operator,
        ctx.session,
        paths,
        parent["eventRef"],
        [parent["eventRef"]],
        scope
      )

    authority = [badge["eventRef"], delegation["eventRef"]]
    text = "harness addition"

    manifest_spec =
      Map.put(ctx.context_spec, "harnessConfiguration", [
        %{"name" => "instruction", "digest" => hash(text), "provenance" => "pinned adapter"}
      ])

    {:ok, manifest} =
      Fixture.admit(
        @local,
        "v1alpha1",
        "ContextManifest",
        nil,
        manifest_spec,
        ctx.operator,
        ctx.operator_authority
      )

    binding_spec =
      Map.merge(ctx.binding, %{
        "badge" => ref(badge["eventRef"]),
        "delegation" => ref(delegation["eventRef"]),
        "contextManifest" => ref(manifest["eventRef"])
      })

    {:ok, binding} =
      Fixture.admit(
        @local,
        "v1alpha1",
        "SessionBinding",
        nil,
        binding_spec,
        ctx.session,
        authority
      )

    body = ~s({"input":"test evidence","system":"harness addition"})
    address = object(body)
    # Setup evidence is genuinely signed and kernel-admitted. This fixture tests
    # the Recurse narrowing policy, not gateway workload policy configuration.
    Application.put_env(:r5e, :policy, R5e.Policy.KernelCedar)
    prompt_spec = %{"contentRef" => ref(address), "session" => ref(ctx.session_ref)}

    {:ok, prompt} =
      Fixture.admit(
        "gateway.r5e.io",
        "v1alpha1",
        "Prompt",
        nil,
        prompt_spec,
        ctx.session,
        authority
      )

    call_spec = %{
      "model" => "model",
      "prompt" => ref("gateway.r5e.io/v1alpha1/Prompt/" <> prompt["name"]),
      "session" => ref(ctx.session_ref)
    }

    {:ok, call} =
      Fixture.admit(
        "gateway.r5e.io",
        "v1alpha1",
        "LlmCall",
        nil,
        call_spec,
        ctx.session,
        authority
      )

    Application.put_env(:r5e, :policy, R5eRecurse.Policy)

    spec = %{
      "sessionBinding" => ref(binding["eventRef"]),
      "llmCall" => ref(call["eventRef"]),
      "inboundBody" => ref(address),
      "outboundBody" => ref(address),
      "bodyDigest" => hash(body),
      "firstInput" => %{"fieldPath" => "/input", "digest" => hash("test evidence")},
      "method" => "POST",
      "path" => "/v1/responses",
      "upstream" => "provider.example",
      "transport" => "https",
      "semanticHeaders" => [],
      "operationId" => "operation",
      "harnessInputs" => []
    }

    {:ok,
     Map.merge(ctx, %{
       authority: authority,
       binding_receipt: binding,
       managed_binding_spec: binding_spec,
       manifest: manifest,
       spec: spec,
       text: text,
       prompt_spec: prompt_spec,
       call_spec: call_spec
     })}
  end

  test "new policy requires inventory but historical omitted inventory remains an immutable record",
       c do
    omitted = Map.delete(c.spec, "harnessInputs")
    # Activate the previous policy source, then the amended admitted bundle.
    old_source =
      File.read!("priv/policy/base.cedar")
      |> String.replace("  context.managed_request_valid &&\n", "")

    old_bundle = Map.put(c.bundle_spec, "sourceRef", ref(object(old_source)))

    assert {:ok, _} =
             Fixture.admit(
               @local,
               "v1alpha1",
               "PolicyBundle",
               "active",
               old_bundle,
               c.operator,
               c.operator_authority
             )

    assert {:ok, old} = submit(c, omitted)

    assert {:ok, _} =
             Fixture.admit(
               @local,
               "v1alpha1",
               "PolicyBundle",
               "active",
               c.bundle_spec,
               c.operator,
               c.operator_authority
             )

    assert {:denied, _} = submit(c, omitted)
    assert {:ok, _} = submit(c, c.spec)

    assert {:ok, %{payload: payload}} =
             R5e.Policy.Facts.run(fn -> R5e.Policy.Facts.event(old["eventRef"]) end, fn result,
                                                                                        _ ->
               result
             end)

    refute Map.has_key?(payload["spec"], "harnessInputs")
  end

  test "canonical manifest provenance is admitted, arbitrary candidate descriptors are refused",
       c do
    item = item(c, c.manifest["eventRef"])
    assert {:ok, _} = submit(c, Map.put(c.spec, "harnessInputs", [item]))

    for items <- [
          [Map.put(item, "digest", hash("wrong"))],
          [item, item],
          [Map.put(item, "fieldPath", "/input")],
          [Map.put(item, "fieldPath", "/bad~2")],
          [Map.put(item, "digest", String.upcase(item["digest"]))],
          [Map.put(item, "fieldPath", "/z"), Map.put(item, "fieldPath", "/a")],
          [Map.put(item, "provenance", ref(c.task["eventRef"]))],
          [Map.put(item, "provenance", ref("event:sha256:" <> String.duplicate("f", 64)))]
        ] do
      assert {:denied, _} = submit(c, Map.put(c.spec, "harnessInputs", items))
    end

    assert {:denied, denied} =
             Fixture.admit(
               @local,
               "v1alpha1",
               "ContextManifest",
               nil,
               Map.put(c.context_spec, "custody", "wrong"),
               c.operator,
               c.operator_authority
             )

    assert {:denied, _} =
             submit(c, Map.put(c.spec, "harnessInputs", [item(c, denied["eventRef"])]))

    {:ok, other} =
      Fixture.admit(
        @local,
        "v1alpha1",
        "ContextManifest",
        nil,
        c.context_spec,
        c.operator,
        c.operator_authority
      )

    assert {:denied, _} =
             submit(c, Map.put(c.spec, "harnessInputs", [item(c, other["eventRef"])]))
  end

  test "only complete same-session signed exact trace artifacts qualify", c do
    base = %{
      "type" => "trace",
      "completeness" => "complete",
      "sessionBinding" => c.spec["sessionBinding"],
      "content" => ref(object(c.text)),
      "mediaType" => "text/plain",
      "sources" => [ref(c.manifest["eventRef"])]
    }

    {:ok, trace} =
      Fixture.admit(@local, "v1alpha1", "Artifact", nil, base, c.session, c.authority)

    assert {:ok, _} = submit(c, Map.put(c.spec, "harnessInputs", [item(c, trace["eventRef"])]))

    {:ok, other_binding} =
      Fixture.admit_binding(c, c.binding, [c.badge["eventRef"], c.delegation["eventRef"]])

    for changes <- [
          %{"type" => "work"},
          %{"completeness" => "partial"},
          %{"sessionBinding" => ref(other_binding["eventRef"])},
          %{"content" => ref(object("different"))}
        ] do
      {:ok, bad} =
        Fixture.admit(
          @local,
          "v1alpha1",
          "Artifact",
          nil,
          Map.merge(base, changes),
          c.session,
          c.authority
        )

      assert {:denied, _} =
               submit(c, Map.put(c.spec, "harnessInputs", [item(c, bad["eventRef"])]))
    end

    {:ok, wrong_actor} =
      Fixture.admit(@local, "v1alpha1", "Artifact", nil, base, c.operator, c.operator_authority)

    assert {:denied, _} =
             submit(c, Map.put(c.spec, "harnessInputs", [item(c, wrong_actor["eventRef"])]))
  end

  test "request relationships are checked even when signed candidates bypass the builder", c do
    {:ok, other_binding} =
      Fixture.admit_binding(c, c.binding, [c.badge["eventRef"], c.delegation["eventRef"]])

    for spec <- [
          Map.put(c.spec, "sessionBinding", ref(other_binding["eventRef"])),
          Map.put(c.spec, "bodyDigest", hash("wrong")),
          Map.put(c.spec, "outboundBody", ref(object("changed")))
        ] do
      assert {:denied, _} = submit(c, spec)
    end

    assert {:denied, _} =
             Fixture.admit(
               @local,
               "v1alpha1",
               "ManagedRequest",
               nil,
               c.spec,
               c.operator,
               c.operator_authority
             )

    assert {:denied, _} =
             Fixture.admit(@local, "v1alpha1", "ManagedRequest", nil, c.spec, c.session, [
               hd(c.authority)
             ])

    # A later admission of identical Prompt bytes by another actor must not
    # replace the immutable Prompt version resolved by the earlier LlmCall.
    Application.put_env(:r5e, :policy, R5e.Policy.KernelCedar)

    grant =
      Fixture.credential(
        "Endorsement",
        :node,
        c.operator,
        ["gateway.r5e.io/v1alpha1/Prompt"],
        nil,
        []
      )

    assert {:ok, _} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "Prompt",
               nil,
               c.prompt_spec,
               c.operator,
               [grant["eventRef"]]
             )

    Application.put_env(:r5e, :policy, R5eRecurse.Policy)
    assert {:ok, _} = submit(c, c.spec)
  end

  test "same actor with another span, wrong call actor, and call before binding refuse", c do
    later =
      Map.put(c.managed_binding_spec, "generation", %{"bootId" => "later", "runId" => "later"})

    assert {:ok, binding} =
             Fixture.admit(
               @local,
               "v1alpha1",
               "SessionBinding",
               nil,
               later,
               c.session,
               c.authority
             )

    assert {:denied, _} = submit(c, Map.put(c.spec, "sessionBinding", ref(binding["eventRef"])))

    Application.put_env(:r5e, :policy, R5e.Policy.KernelCedar)

    assert {:ok, span} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "AgentSession",
               nil,
               %{},
               c.session,
               c.authority
             )

    call =
      Map.put(
        c.call_spec,
        "session",
        ref("gateway.r5e.io/v1alpha1/AgentSession/" <> span["name"])
      )

    assert {:ok, crossed} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "LlmCall",
               nil,
               call,
               c.session,
               c.authority
             )

    grant =
      Fixture.credential(
        "Endorsement",
        :node,
        c.operator,
        ["gateway.r5e.io/v1alpha1/LlmCall"],
        nil,
        []
      )

    assert {:ok, wrong_actor} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "LlmCall",
               nil,
               c.call_spec,
               c.operator,
               [grant["eventRef"]]
             )

    Application.put_env(:r5e, :policy, R5eRecurse.Policy)

    for receipt <- [crossed, wrong_actor] do
      assert {:denied, _} = submit(c, Map.put(c.spec, "llmCall", ref(receipt["eventRef"])))
    end
  end

  defp submit(c, spec),
    do: Fixture.admit(@local, "v1alpha1", "ManagedRequest", nil, spec, c.session, c.authority)

  defp item(c, source),
    do: %{"fieldPath" => "/system", "digest" => hash(c.text), "provenance" => ref(source)}

  defp ref(value), do: %{"$ref" => value}
  defp hash(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp object(bytes) do
    {:ok, _, address, _} = R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), bytes, "text/plain")
    address
  end
end
