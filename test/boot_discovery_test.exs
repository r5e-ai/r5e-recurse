defmodule R5eRecurse.BootDiscoveryTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.{Boot.Discovery, KernelClient}
  alias RecurseVerify.{Canonical, Chain, DSSE}
  @origin "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  # Signed protocol fixtures test the read boundary, not kernel policy admission.
  defmodule Snapshot do
    import Plug.Conn
    def init(state), do: state

    def call(conn, state) do
      {status, body} =
        Agent.get_and_update(state, fn s ->
          if conn.request_path == "/events" do
            events = if s.reads > 0 and s.change, do: [], else: s.events
            {{200, Jason.encode!(%{"events" => events})}, %{s | reads: s.reads + 1}}
          else
            response =
              case s.cas_failure do
                :missing ->
                  {404, "missing"}

                :altered ->
                  {200, "altered"}

                nil ->
                  {200, Map.fetch!(s.cas, String.replace_prefix(conn.request_path, "/cas/", ""))}
              end

            {response, s}
          end
        end)

      if conn.method != "GET", do: raise("discovery attempted mutation")
      send_resp(conn, status, body)
    end
  end

  test "enumerates an old active binding before any lifecycle citation" do
    f = fixture()
    assert {:ok, inventory} = read(f)
    assert [entry] = inventory.old_active
    assert entry.binding == f.binding
    assert entry.badge == f.badge
    assert entry.delegation == f.delegation
    assert entry.issuer == f.issuer.id
    assert entry.subject == f.session.id
    assert entry.blockers == []
    assert inventory.unattached == [entry]
    assert inventory.complete_boot == false
    assert :journal_reserved_intents in inventory.integration_dependencies
    assert inventory.checkpoint == Map.take(List.last(f.events), ~w(seq hash))
  end

  test "classifies attached active, interrupted, terminal and current boot independently" do
    for {transition, category} <- [{"interrupted", :old_interrupted}, {"failed", :old_terminal}] do
      f = fixture() |> lifecycle(transition)
      assert {:ok, inventory} = read(f)
      assert [%{status: ^transition, lifecycle_attached: true}] = inventory[category]
      assert inventory.unattached == []
    end

    f = fixture() |> lifecycle("ready") |> lifecycle("running")
    assert {:ok, %{old_active: [%{status: "running"}]}} = read(f)
    assert {:ok, %{current_boot: [_], old_active: []}} = read(f, "old")
  end

  test "missing durable preparing is a blocker and never synthesized" do
    f = fixture(preparing: false)
    assert {:ok, inventory} = read(f)
    assert Enum.any?(inventory.blockers, &(&1.reason == :missing_durable_preparation))
    assert inventory.attempts[f.task].status == "admitted"
    assert inventory.attempts[f.task].generation == nil
  end

  test "closure before binding remains inventoried with an explicit ordering blocker" do
    for transition <- ~w(failed interrupted outcome_unknown) do
      f = fixture(closure_before_binding: transition)
      assert {:ok, inventory} = read(f)
      assert [entry] = inventory.bindings
      assert entry.binding == f.binding
      refute entry.lifecycle_attached
      assert entry.blockers == [%{binding: f.binding, reason: :binding_after_closure}]
    end
  end

  test "preparation after a credential is not durable setup provenance" do
    assert {:ok, inventory} = read(fixture(preparing: false, late_preparation: true))
    assert [%{reason: :missing_durable_preparation}] = inventory.blockers
  end

  test "CAS missing history and altered bytes propagate as errors" do
    f = fixture()
    assert {:error, :not_found} = read(f, "new", cas_failure: :missing)
    assert {:error, :digest_mismatch} = read(f, "new", cas_failure: :altered)
  end

  test "uncited retry binding cannot silently reuse the earlier session key" do
    f = fixture() |> lifecycle("interrupted")
    old = f
    f = add(f, "ReconciliationObservation", %{"interruption" => ref(f.prior)}, f.issuer)

    f =
      add(
        f,
        "RecoveryDecision",
        %{
          "task" => ref(old.task),
          "interruption" => ref(old.prior),
          "observationRef" => ref(f.last),
          "disposition" => "retry"
        },
        f.issuer
      )

    f =
      add(
        f,
        "Task",
        %{
          "id" => "retry",
          "step" => "produce",
          "delegatedBy" => f.issuer.id,
          "earlierTask" => ref(old.task),
          "recoveryDecision" => ref(f.last)
        },
        f.issuer
      )

    f = %{
      f
      | task: f.last,
        prior: nil,
        binding: nil,
        generation: %{"bootId" => "old", "runId" => "retry"}
    }

    f = lifecycle(f, "preparing")
    credential = %{"subject" => f.session.id, "scope" => %{"task" => f.task}}
    f = add(f, "Badge", credential, f.issuer)
    f = %{f | badge: f.last}
    f = add(f, "Endorsement", credential, f.issuer)
    f = %{f | delegation: f.last}
    f = add(f, "AgentSession", %{}, f.session)

    spec = %{
      "task" => ref(f.task),
      "generation" => f.generation,
      "badge" => ref(f.badge),
      "delegation" => ref(f.delegation),
      "agentSessionAdmission" => ref(f.last),
      "agentSession" => ref("gateway.r5e.io/v1alpha1/AgentSession/" <> f.last),
      "sessionKey" => f.session.id,
      "actorType" => "agent"
    }

    f = add(f, "SessionBinding", spec, f.session, [f.badge, f.delegation])
    f = %{f | binding: f.last}
    assert {:ok, inventory} = read(f)
    assert [entry] = inventory.old_active
    refute entry.lifecycle_attached
    assert entry.blockers == [%{binding: f.binding, reason: :retry_reused_session}]
    assert {:error, :retry_reused_session} = f |> lifecycle("ready") |> read()
  end

  test "duplicate immutable bindings cannot hide behind one lifecycle citation" do
    f = fixture()
    original = List.last(f.payloads)
    f = add(f, "SessionBinding", original["spec"], f.session, original["authority"])
    assert {:ok, inventory} = read(f)
    assert length(inventory.bindings) == 2
    assert Enum.count(inventory.blockers, &(&1.reason == :ambiguous_attempt_bindings)) == 2
  end

  test "subject or delegation issuer mismatch blocks provenance" do
    for option <- [:wrong_subject, :wrong_issuer] do
      assert {:ok, inventory} = read(fixture([{option, true}]))
      assert Enum.any?(inventory.blockers, &(&1.reason == :unresolved_binding_provenance))
      assert inventory.old_active == []
    end
  end

  test "invalid lifecycle remains an error" do
    assert {:error, :illegal_transition} = fixture() |> lifecycle("running") |> read()
  end

  test "bad signatures, copied actor, and origin are rejected" do
    f = fixture()

    for mutate <- [
          fn p ->
            put_in(p, ["signed", "signatures", Access.at(0), "sig"], Base.encode64(<<0::512>>))
          end,
          fn p -> put_in(p, ["actor", "id"], "wrong") end,
          fn p -> Map.put(p, "origin", "wrong") end
        ] do
      changed = replace_last(f, mutate)
      assert {:error, {:unverified_admission, _}} = read(changed)
    end

    assert {:error, {:unverified_admission, _}} = read(f, "new", origin: "other")
  end

  test "changed second event snapshot fails closed" do
    assert {:error, :changing_head} = read(fixture(), "new", change: true)
  end

  test "unrelated badges never become inventory or revocation targets" do
    f = fixture()
    f = add(f, "Badge", %{"subject" => f.session.id}, f.issuer)
    assert {:ok, %{bindings: [entry]}} = read(f)
    assert entry.badge != f.last
  end

  test "server-named span target omits name and resolves through its exact admission" do
    f = fixture()
    span = Enum.find(f.payloads, &(&1["target"]["kind"] == "AgentSession"))
    refute Map.has_key?(span["target"], "name")
    assert span["submittedTarget"]["name"] == nil
    assert {:ok, %{old_active: [%{blockers: []}]}} = read(f)

    # A different descriptive span name cannot substitute for this admission.
    binding = List.last(f.payloads)

    spec =
      Map.put(binding["spec"], "agentSession", ref("gateway.r5e.io/v1alpha1/AgentSession/other"))

    f = %{f | events: Enum.drop(f.events, -1), payloads: Enum.drop(f.payloads, -1)}
    f = add(f, "SessionBinding", spec, f.session, binding["authority"])
    assert {:ok, inventory} = read(f)
    assert Enum.any?(inventory.blockers, &(&1.reason == :unresolved_binding_provenance))
  end

  test "denied binding references cannot pull unrelated credentials into verification" do
    f = fixture()
    binding = List.last(f.payloads)
    f = add(f, "Badge", %{"subject" => f.session.id}, f.issuer)
    # Deliberately invalid unrelated credential detects accidental selection.
    f = replace_last(f, &Map.put(&1, "identity", "unsigned"))
    unrelated_badge = f.last

    denied =
      binding
      |> Map.put("outcome", "denied")
      |> put_in(["spec", "badge"], ref(unrelated_badge))

    f = append(f, denied, "admission.denied")
    assert {:ok, %{bindings: [entry], blockers: []}} = read(f)
    assert entry.badge != unrelated_badge
    assert entry.badge == f.badge
  end

  test "contradictory grant and outcome remain an error" do
    f = fixture() |> replace_last(&Map.put(&1, "outcome", "denied"))
    assert {:error, {:unverified_admission, _}} = read(f)
  end

  defp read(f, boot \\ "new", opts \\ []) do
    cas =
      Map.new(Enum.zip(f.events, f.payloads), fn {e, p} -> {e["payload"], Canonical.encode(p)} end)

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          events: f.events,
          cas: cas,
          reads: 0,
          change: opts[:change],
          cas_failure: opts[:cas_failure]
        }
      end)

    {:ok, server} = Bandit.start_link(plug: {Snapshot, state}, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    try do
      Discovery.read(KernelClient.new("http://127.0.0.1:#{port}"), opts[:origin] || @origin, boot)
    after
      GenServer.stop(server)
      Agent.stop(state)
    end
  end

  defp fixture(opts \\ []) do
    issuer = key()
    session = key()

    f = %{
      issuer: issuer,
      session: session,
      events: [],
      payloads: [],
      generation: %{"bootId" => "old", "runId" => "run"}
    }

    f = add(f, "Task", %{"id" => "task", "step" => "produce", "delegatedBy" => issuer.id}, issuer)
    f = Map.put(f, :task, f.last)
    f = Map.put(f, :prior, nil)
    f = if Keyword.get(opts, :preparing, true), do: lifecycle(f, "preparing"), else: f
    credential = %{"subject" => session.id, "scope" => %{"task" => f.task}}

    badge =
      if opts[:wrong_subject], do: Map.put(credential, "subject", issuer.id), else: credential

    f = add(f, "Badge", badge, issuer)
    f = Map.put(f, :badge, f.last)
    f = if opts[:late_preparation], do: lifecycle(f, "preparing"), else: f
    f = add(f, "Endorsement", credential, if(opts[:wrong_issuer], do: session, else: issuer))
    f = Map.put(f, :delegation, f.last)
    f = add(f, "AgentSession", %{}, session)

    spec = %{
      "task" => ref(f.task),
      "badge" => ref(f.badge),
      "delegation" => ref(f.delegation),
      "agentSessionAdmission" => ref(f.last),
      "agentSession" => ref("gateway.r5e.io/v1alpha1/AgentSession/" <> f.last),
      "generation" => f.generation,
      "sessionKey" => session.id,
      "actorType" => "agent"
    }

    f = if opts[:closure_before_binding], do: lifecycle(f, opts[:closure_before_binding]), else: f
    f = add(f, "SessionBinding", spec, session, [f.badge, f.delegation])
    Map.put(f, :binding, f.last)
  end

  defp lifecycle(f, transition) do
    spec = %{
      "task" => ref(f.task),
      "transition" => transition,
      "generation" => f.generation,
      "priorLifecycle" => if(f.prior, do: ref(f.prior)),
      "sessionBinding" => if(f[:binding], do: ref(f.binding))
    }

    f = add(f, "LifecycleEvent", spec, f.issuer)
    %{f | prior: f.last}
  end

  defp add(f, kind, spec, signer, authority \\ []) do
    {group, version} =
      cond do
        kind in ~w(Badge Endorsement) -> {"core.r5e.io", "v1"}
        kind == "AgentSession" -> {"gateway.r5e.io", "v1alpha1"}
        true -> {"recurse.r5e.io", "v1alpha1"}
      end

    target = %{
      "group" => group,
      "version" => version,
      "kind" => kind,
      "name" => nil
    }

    request = %{
      "origin" => @origin,
      "actor" => signer.id,
      "target" => target,
      "specAddress" => Canonical.hash(spec),
      "derivedFrom" => nil,
      "authority" => authority,
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "expires" => "2099-01-01T00:00:00Z"
    }

    bytes = Canonical.encode(request)
    type = "application/vnd.r5e.admission-request+json;v=1"
    sig = :crypto.sign(:eddsa, :none, DSSE.pae(type, bytes), [signer.private, :ed25519])

    envelope = %{
      "payloadType" => type,
      "payload" => Base.encode64(bytes),
      "signatures" => [%{"keyid" => signer.id, "sig" => Base.encode64(sig)}],
      "publicKeys" => [
        %{"keyid" => signer.id, "algorithm" => "ed25519", "bytes" => Base.encode64(signer.public)}
      ]
    }

    p =
      Map.merge(Map.take(request, ~w(origin derivedFrom authority nonce expires)), %{
        "actor" => %{
          "id" => signer.id,
          "algorithm" => "ed25519",
          "publicKey" => Base.encode64(signer.public)
        },
        "identity" => "signed",
        "signed" => envelope,
        "submittedTarget" => target,
        "target" => if(kind == "AgentSession", do: Map.delete(target, "name"), else: target),
        "spec" => spec,
        "outcome" => "admitted"
      })

    append(f, p)
  end

  defp append(f, p, event_kind \\ "admission.granted") do
    e = %{
      "seq" => length(f.events) + 1,
      "prev" => if(f.events == [], do: Chain.genesis(), else: List.last(f.events)["hash"]),
      "payload" => Canonical.hash(p),
      "kind" => event_kind,
      "ts" => "2026-01-01T00:00:00Z"
    }

    e = Map.put(e, "hash", Canonical.hash(e))

    Map.merge(f, %{
      events: f.events ++ [e],
      payloads: f.payloads ++ [p],
      last: "event:" <> e["hash"]
    })
  end

  defp replace_last(f, fun) do
    p = fun.(List.last(f.payloads))
    append(%{f | events: Enum.drop(f.events, -1), payloads: Enum.drop(f.payloads, -1)}, p)
  end

  defp ref(id), do: %{"$ref" => id}

  defp key do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private, id: DSSE.key_id!("ed25519", public)}
  end
end
