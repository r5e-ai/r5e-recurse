defmodule R5eRecurse.RecoveryAdmissionTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{Boot, KernelClient, IsolatedKernel, DroppingProxy, NonceJournal}
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
      boundary: boundary(Map.put(ctx, :signer, signer), client),
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
    assert {:ok, ^receipt} = Boot.recover(boot, :revocation, candidate)
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
    boundary = boundary(ctx, proxy)

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

    {:ok, recorded} = KernelClient.events_from(ctx.client, 1)
    GenServer.stop(ctx.boundary.journal)
    parent = self()

    marker = fn _, _, _, _ ->
      send(parent, :unexpected_observation_signature)
      {:error, :unavailable}
    end

    recovered =
      boundary(%{ctx | signer: marker}, ctx.client,
        directory: ctx.boundary.test_directory,
        boot: "observation-recovery"
      )

    assert {:ok, _} = Admission.admit(recovered, :observation, observation)

    assert {:conflict, _} =
             Admission.admit(recovered, :observation, %{
               observation
               | spec: Map.put(observation.spec, "result", "succeeded")
             })

    refute_receive :unexpected_observation_signature
    assert {:ok, ^recorded} = KernelClient.events_from(ctx.client, 1)
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

    boundary = boundary(ctx, proxy)
    {:ok, before} = KernelClient.events_from(ctx.client, 1)

    assert {:outcome_unknown, %{event_ref: ref, reason: :canonical_confirmation_unavailable}} =
             Admission.admit(boundary, :revocation, Map.take(ctx, [:badge, :issuer]))

    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    assert ref == "event:" <> event["hash"]
    assert event["kind"] == "admission.granted"
  end

  test "lost acknowledgement recovers the same revocation across a new boot without signing",
       ctx do
    proxy = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :post_retry_after))
    old = boundary(ctx, proxy)
    candidate = Map.take(ctx, [:badge, :issuer])
    assert {:outcome_unknown, _} = Admission.admit(old, :revocation, candidate)
    {:ok, after_write} = KernelClient.events_from(ctx.client, 1)
    GenServer.stop(old.journal)
    parent = self()

    marker = fn _, _, _, _ ->
      send(parent, :unexpected_recovery_signature)
      {:error, :unavailable}
    end

    next =
      boundary(%{ctx | signer: marker}, ctx.client,
        directory: old.test_directory,
        boot: "new-boot"
      )

    assert {:ok, receipt} = Admission.admit(next, :revocation, candidate)
    assert receipt.event_ref == "event:" <> List.last(after_write)["hash"]
    assert {:ok, ^after_write} = KernelClient.events_from(ctx.client, 1)
    refute_receive :unexpected_recovery_signature
    assert {:conflict, _} = Admission.admit(next, :revocation, %{candidate | issuer: "changed"})
    refute_receive :unexpected_recovery_signature
  end

  test "reserved recovery operation stays uncertain across boots without signing or submitting",
       ctx do
    parent = self()

    refusing = %{
      ctx
      | signer: fn _, _, _, _ ->
          send(parent, :first_attempt)
          {:error, :unavailable}
        end
    }

    old = boundary(refusing, ctx.client)
    candidate = Map.take(ctx, [:badge, :issuer])
    {:ok, before} = KernelClient.events_from(ctx.client, 1)
    assert {:outcome_unknown, _} = Admission.admit(old, :revocation, candidate)
    assert_receive :first_attempt
    GenServer.stop(old.journal)
    next = boundary(refusing, ctx.client, directory: old.test_directory, boot: "next-boot")

    assert {:outcome_unknown, %{reason: :signing_unconfirmed}} =
             Admission.admit(next, :revocation, candidate)

    refute_receive :first_attempt
    assert {:ok, ^before} = KernelClient.events_from(ctx.client, 1)
  end

  test "unavailable journal never becomes a confirmed recovery or an ordinary preparation failure",
       ctx do
    GenServer.stop(ctx.boundary.journal)

    assert {:outcome_unknown, %{reason: :recovery_boundary_unavailable}} =
             Admission.admit(ctx.boundary, :revocation, Map.take(ctx, [:badge, :issuer]))
  end

  test "a competing same-spec journal result cannot substitute authority, even for a denial",
       ctx do
    candidate = Map.take(ctx, [:badge, :issuer])

    other =
      sign(ctx, target("Revocation"), %{"revokes" => %{"$ref" => ctx.badge}}, [
        "event:sha256:" <> String.duplicate("f", 64)
      ])

    # Model the journal race: metadata was absent, then another caller completed
    # the same target/spec under different authority before submit_once ran.
    for outcome <- [:ok, :denied] do
      journal =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:operation, _}} -> GenServer.reply(from, :missing)
          end

          receive do
            {:"$gen_call", from, {:submit, _, _, _, _}} ->
              GenServer.reply(from, {outcome, %{}, other})
          end
        end)

      assert {:conflict, %{reason: :recovery_authority_changed}} =
               Admission.admit(%{ctx.boundary | journal: journal}, :revocation, candidate)
    end
  end

  defp boundary(ctx, client, opts \\ []) do
    directory =
      Keyword.get_lazy(opts, :directory, fn ->
        Path.join(System.tmp_dir!(), "recovery-journal-#{System.unique_integer([:positive])}")
      end)

    boot = Keyword.get(opts, :boot, "recovery-boot")
    on_exit(fn -> File.rm_rf!(directory) end)

    journal =
      start_supervised!(
        Supervisor.child_spec(
          {NonceJournal, directory: directory, client: client, origin: ctx.origin, boot_id: boot},
          id: make_ref(),
          restart: :temporary
        )
      )

    Admission.new(client, ctx.origin, ctx.signer,
      journal: journal,
      generation: %{"bootId" => boot, "runId" => "recovery"}
    )
    |> Map.put(:test_directory, directory)
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
