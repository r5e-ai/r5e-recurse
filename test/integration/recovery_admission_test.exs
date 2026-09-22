defmodule R5eRecurse.RecoveryAdmissionTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{Boot, KernelClient, IsolatedKernel, DroppingProxy}
  alias R5eRecurse.Boot.Admission
  @moduletag skip: is_nil(System.get_env("R5E_TEST_KERNEL_IMAGE"))

  setup do
    kernel = IsolatedKernel.start!()
    client = KernelClient.new(kernel.url)
    {:ok, [first | _]} = KernelClient.events_from(client, 1)
    {:ok, bytes} = KernelClient.get_cas(client, first["payload"])
    ctx = %{kernel: kernel, client: client, origin: Jason.decode!(bytes)["origin"]}
    # Disposable fixture key; the deployment node key stays inside its container.
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    subject = %{public: public, private: private}

    spec = %{
      "subject" => RecurseVerify.DSSE.key_id!("ed25519", public),
      "subjectKey" => %{"algorithm" => "ed25519", "bytes" => Base.encode64(public)},
      "subjectKind" => "agent",
      "kinds" => ["core.r5e.io/v1/CasObject"],
      "mayIssue" => false,
      "notBefore" => "2020-01-01T00:00:00Z",
      "notAfter" => "2035-01-01T00:00:00Z"
    }

    target = target("Badge")
    envelope = sign(ctx, target, spec, [])
    payload = Base.decode64!(envelope["payload"])

    signature =
      :crypto.sign(:eddsa, :none, RecurseVerify.DSSE.pae(envelope["payloadType"], payload), [
        private,
        :ed25519
      ])

    envelope =
      envelope
      |> Map.update!(
        "signatures",
        &(&1 ++ [%{"keyid" => spec["subject"], "sig" => Base.encode64(signature)}])
      )
      |> Map.update!(
        "publicKeys",
        &(&1 ++
            [
              %{
                "keyid" => spec["subject"],
                "algorithm" => "ed25519",
                "bytes" => Base.encode64(public)
              }
            ])
      )

    assert {:ok, badge} = KernelClient.submit(client, target, envelope, spec)
    issuer = Jason.decode!(payload)["actor"]
    signer = fn target, spec, _issuer, authority -> {:ok, sign(ctx, target, spec, authority)} end

    Map.merge(ctx, %{
      badge: badge["eventRef"],
      issuer: issuer,
      subject: subject,
      boundary: Admission.new(client, ctx.origin, signer),
      signer: signer
    })
  end

  test "real issuer revocation is confirmed from canonical history before recovery succeeds",
       ctx do
    candidate = Map.take(ctx, [:badge, :issuer])
    {:ok, boot} = Boot.start_link(boundary: %{admit: &Admission.admit(ctx.boundary, &1, &2)})
    assert {:ok, receipt} = Boot.recover(boot, :revocation, candidate)
    assert receipt.badge == ctx.badge
    assert receipt.issuer == ctx.issuer
    assert {:ok, records} = R5eRecurse.Commands.KernelStore.history(ctx.client)
    record = Enum.find(records, &("event:" <> &1.event["hash"] == receipt.event_ref))
    assert record.payload["target"]["kind"] == "Revocation"
    assert record.payload["spec"]["revokes"]["$ref"] == ctx.badge
    assert record.payload["actor"]["id"] == ctx.issuer
    refute Boot.mutation_allowed?(boot)
  end

  test "wrong issuer and lost acknowledgement cannot confirm revocation or resubmit", ctx do
    assert {:error, :badge_issuer_unconfirmed} =
             Admission.admit(ctx.boundary, :revocation, %{
               badge: ctx.badge,
               issuer: RecurseVerify.DSSE.key_id!("ed25519", ctx.subject.public)
             })

    {:ok, before} = KernelClient.events_from(ctx.client, 1)
    proxy = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :post_retry_after))
    boundary = Admission.new(proxy, ctx.origin, ctx.signer)

    assert {:outcome_unknown, _} =
             Admission.admit(boundary, :revocation, Map.take(ctx, [:badge, :issuer]))

    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    assert event["kind"] == "admission.granted"
  end

  test "canonical observation and issuer revocation open the recovery barrier together", ctx do
    # Minimal LifecycleEvent schema isolates recovery admission. A managed session
    # must still supply the real interrupted binding/lifecycle driver.
    lifecycle_kind = %{
      "group" => "recurse.r5e.io",
      "version" => "v1alpha1",
      "kind" => "LifecycleEvent",
      "substrate" => "event",
      "naming" => %{"mode" => "content"},
      "schema" => %{"properties" => %{}, "required" => [], "additionalProperties" => false},
      "predicates" => []
    }

    observation_kind = File.read!("priv/kinds/reconciliation-observation.json") |> Jason.decode!()

    for definition <- [lifecycle_kind, observation_kind] do
      assert {:ok, _} =
               KernelClient.submit(
                 ctx.client,
                 target("KindDefinition"),
                 sign(ctx, target("KindDefinition"), definition, []),
                 definition
               )
    end

    lifecycle_target = %{
      "group" => "recurse.r5e.io",
      "version" => "v1alpha1",
      "kind" => "LifecycleEvent",
      "name" => nil
    }

    assert {:ok, interruption} =
             KernelClient.submit(
               ctx.client,
               lifecycle_target,
               sign(ctx, lifecycle_target, %{}, []),
               %{}
             )

    probe = sign(ctx, target("Endorsement"), %{}, [])
    key = Enum.find(probe["publicKeys"], &(&1["keyid"] == ctx.issuer))

    endorsement = %{
      "subject" => ctx.issuer,
      "subjectKey" => Map.take(key, ["algorithm", "bytes"]),
      "kinds" => ["recurse.r5e.io/v1alpha1/ReconciliationObservation"],
      "mayIssue" => false,
      "notBefore" => "2020-01-01T00:00:00Z",
      "notAfter" => "2035-01-01T00:00:00Z"
    }

    assert {:ok, grant} =
             KernelClient.submit(
               ctx.client,
               target("Endorsement"),
               sign(ctx, target("Endorsement"), endorsement, []),
               endorsement
             )

    observation = %{
      issuer: ctx.issuer,
      authority: [grant["eventRef"]],
      spec: %{
        "interruption" => %{"$ref" => interruption["eventRef"]},
        "method" => "fixture-owned-process-observation",
        "evidence" => [],
        "result" => "unknown"
      }
    }

    boundary = %{
      interrupted: fn -> {:ok, [Map.take(ctx, [:badge, :issuer])]} end,
      reconcile: fn _ -> {:ok, observation} end,
      admit: &Admission.admit(ctx.boundary, &1, &2)
    }

    {:ok, gate} = Boot.start_link(boundary: boundary)
    assert :ok = Boot.reconcile(gate)
    assert Boot.mutation_allowed?(gate)
    {:ok, records} = R5eRecurse.Commands.KernelStore.history(ctx.client)

    assert Enum.any?(
             records,
             &(&1.payload["target"]["kind"] == "ReconciliationObservation" and
                 &1.payload["spec"] == observation.spec)
           )
  end

  test "confirmation failure after successful POST stays uncertain with the recorded reference",
       ctx do
    state = start_supervised!({Agent, fn -> false end})

    proxy =
      KernelClient.new(DroppingProxy.start!(ctx.kernel.url, {:fail_history_after_post, state}))

    boundary = Admission.new(proxy, ctx.origin, ctx.signer)
    {:ok, before} = KernelClient.events_from(ctx.client, 1)

    assert {:outcome_unknown, %{event_ref: ref, reason: :canonical_confirmation_unavailable}} =
             Admission.admit(boundary, :revocation, Map.take(ctx, [:badge, :issuer]))

    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    assert ref == "event:" <> event["hash"]
    assert event["kind"] == "admission.granted"
  end

  defp target(kind),
    do: %{"group" => "core.r5e.io", "version" => "v1", "kind" => kind, "name" => nil}

  defp sign(ctx, target, spec, authority) do
    encoded =
      Base.encode64(
        Jason.encode!(%{target: target, spec: spec, origin: ctx.origin, authority: authority})
      )

    script =
      "Application.put_env(:r5e, :data_dir, System.fetch_env!(\"R5E_DATA_DIR\")); x = Jason.decode!(Base.decode64!(\"#{encoded}\")); IO.puts(Jason.encode!(R5e.Request.sign(%{target: x[\"target\"], spec: x[\"spec\"], authority: x[\"authority\"]}, [:node], origin: x[\"origin\"])))"

    {output, 0} =
      System.cmd(
        "docker",
        ["exec", ctx.kernel.container, "/app/bin/audit_console", "eval", script],
        stderr_to_stdout: true
      )

    output |> String.trim() |> Jason.decode!()
  end
end
