defmodule R5eRecurse.CommandsTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.Commands
  alias R5eRecurse.Commands.{Envelope, OperatorSignature}
  alias RecurseVerify.{Canonical, DSSE}

  defmodule StoreFixture do
    # Explicit contract fixture, not an isolated-kernel acceptance test.
    def history(pid), do: Agent.get(pid, &{:ok, &1.records})

    def submit(pid, spec, envelope) do
      Agent.get_and_update(pid, fn state ->
        request = envelope["payload"] |> Base.decode64!() |> Jason.decode!()
        seq = length(state.records) + 1
        nonce = {request["actor"], request["nonce"]}
        replay = MapSet.member?(state.nonces, nonce)
        outcome = if replay or state.mode == :denied, do: "denied", else: "admitted"

        payload = %{
          "identity" => "signed",
          "signed" => envelope,
          "submittedTarget" => request["target"],
          "actor" => %{"id" => request["actor"]},
          "origin" => request["origin"],
          "nonce" => request["nonce"],
          "target" => Envelope.target(),
          "spec" => spec,
          "outcome" => outcome
        }

        payload =
          if replay,
            do:
              Map.put(
                payload,
                "reason",
                "authenticate: nonce replayed: this chain has already recorded the nonce from this signer"
              ),
            else: payload

        payload =
          if state.mode == :denied,
            do: Map.put(payload, "reason", "authorize: policy refused"),
            else: payload

        hash = Canonical.hash([seq, payload])
        event = %{"seq" => seq, "hash" => hash}
        receipt = %{"eventRef" => "event:" <> hash, "outcome" => outcome, "recorded" => true}

        response =
          cond do
            replay -> {:denied, Map.put(receipt, "reason", "nonce replayed")}
            state.mode == :denied -> {:outcome_unknown, :connection_lost}
            state.mode == :drop -> {:outcome_unknown, :connection_lost}
            true -> {:ok, receipt}
          end

        next = %{
          state
          | submissions: state.submissions + 1,
            nonces: MapSet.put(state.nonces, nonce)
        }

        next =
          if state.mode == :unseen,
            do: next,
            else: %{next | records: state.records ++ [%{event: event, payload: payload}]}

        response =
          if state.mode == :unseen, do: {:outcome_unknown, :connection_lost}, else: response

        {response, next}
      end)
    end
  end

  setup do
    origin = Canonical.hash(:crypto.strong_rand_bytes(16) |> Base.encode64())
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, store} =
      Agent.start_link(fn ->
        %{records: [], nonces: MapSet.new(), submissions: 0, mode: :normal}
      end)

    opts = [origin: origin, store: {StoreFixture, store}, operator_keys: [public]]
    {:ok, server} = Commands.start_link(opts)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    %{server: server, store: store, origin: origin, public: public, private: private, opts: opts}
  end

  defp command(ctx, changes \\ %{}),
    do:
      Map.merge(
        %{
          "command_id" => "stable",
          "operation" => "submit_task",
          "origin" => ctx.origin,
          "target" => "node-1",
          "expected_state_ref" => nil,
          "payload" => %{"objective" => "test"}
        },
        changes
      )

  defp caller(ctx), do: DSSE.key_id!("ed25519", ctx.public)

  defp signed(ctx, command, nonce \\ Base.encode64(:crypto.strong_rand_bytes(16))) do
    {:ok, spec} = Commands.command_spec(command, caller(ctx))

    request = %{
      "origin" => ctx.origin,
      "actor" => caller(ctx),
      "target" => Envelope.target(),
      "specAddress" => Canonical.hash(spec),
      "derivedFrom" => nil,
      "authority" => [],
      "nonce" => nonce,
      "expires" => "2099-01-01T00:00:00Z"
    }

    payload = Canonical.encode(request)
    type = "application/vnd.r5e.admission-request+json;v=1"
    signature = :crypto.sign(:eddsa, :none, DSSE.pae(type, payload), [ctx.private, :ed25519])

    %{
      "payloadType" => type,
      "payload" => Base.encode64(payload),
      "signatures" => [%{"keyid" => caller(ctx), "sig" => Base.encode64(signature)}],
      "publicKeys" => [
        %{"keyid" => caller(ctx), "algorithm" => "ed25519", "bytes" => Base.encode64(ctx.public)}
      ]
    }
  end

  test "semantic retries return existing, differing payload conflicts without submission", ctx do
    command = command(ctx)

    assert {:accepted, %{execution: :not_implemented} = result} =
             Commands.submit(ctx.server, command, signed(ctx, command))

    assert {:existing, ^result} = Commands.submit(ctx.server, command, signed(ctx, command))
    changed = put_in(command["payload"]["objective"], "changed")
    assert {:conflict, _} = Commands.submit(ctx.server, changed, signed(ctx, changed))
    assert Agent.get(ctx.store, & &1.submissions) == 1
  end

  test "lost acknowledgement resolves by canonical ID lookup with no fresh submission", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :drop})
    command = command(ctx)
    assert {:outcome_unknown, _} = Commands.submit(ctx.server, command, signed(ctx, command))

    assert {:existing, %{execution: :not_implemented}} =
             Commands.lookup(ctx.server, caller(ctx), "stable")

    assert Agent.get(ctx.store, & &1.submissions) == 1
    GenServer.stop(ctx.server)
    {:ok, restarted} = Commands.start_link(ctx.opts)
    assert {:existing, _} = Commands.lookup(restarted, caller(ctx), "stable")
    GenServer.stop(restarted)
  end

  test "a lost denial acknowledgement is recoverable by command identity", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :denied})
    command = command(ctx)
    assert {:outcome_unknown, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    assert {:existing, %{outcome: "denied"}} = Commands.lookup(ctx.server, caller(ctx), "stable")
    assert Agent.get(ctx.store, & &1.submissions) == 1
  end

  test "unseen submission stays uncertain across restart; different digest conflicts", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :unseen})
    command = command(ctx)
    assert {:outcome_unknown, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    GenServer.stop(ctx.server)
    {:ok, restarted} = Commands.start_link(ctx.opts)
    assert {:outcome_unknown, _} = Commands.submit(restarted, command, signed(ctx, command))
    assert {:outcome_unknown, _} = Commands.lookup(restarted, caller(ctx), "stable")
    changed = put_in(command["payload"]["objective"], "different")
    assert {:conflict, _} = Commands.submit(restarted, changed, signed(ctx, changed))
    assert Agent.get(ctx.store, & &1.submissions) == 1
    GenServer.stop(restarted)
  end

  test "protocol replay goes to kernel fixture for a recorded denial", ctx do
    command = command(ctx)
    envelope = signed(ctx, command)
    assert {:accepted, _} = Commands.submit(ctx.server, command, envelope)

    assert {:denied, %{"recorded" => true, "reason" => "nonce replayed"}} =
             Commands.submit(ctx.server, command, envelope)

    assert {:existing, _} = Commands.lookup(ctx.server, caller(ctx), "stable")
    assert Agent.get(ctx.store, & &1.submissions) == 2
  end

  test "caller identity scopes IDs, signature tampering fails, service key cannot decide", ctx do
    command = command(ctx)
    assert {:accepted, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    other = %{ctx | public: public, private: private}
    assert {:accepted, _} = Commands.submit(ctx.server, command, signed(other, command))
    decision = command(ctx, %{"operation" => "record_decision", "command_id" => "decision"})

    assert {:error, :operator_signature_required} =
             Commands.submit(ctx.server, decision, signed(other, decision))

    assert {:error, :invalid_command_signature} =
             Commands.submit(ctx.server, decision, signed(ctx, command))

    assert {:accepted, _} = Commands.submit(ctx.server, decision, signed(ctx, decision))
  end

  test "a separate OS process cannot acquire the active origin lock", ctx do
    directory = "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(ctx.origin, "sha256:", "")
    helper = Application.app_dir(:r5e_recurse, "priv/commands/ownership.py")
    assert {"busy\n", 3} = System.cmd("python3", [helper, directory])

    assert Enum.sort(Commands.operations()) ==
             Enum.sort(
               ~w(submit_task start_session cancel_session record_decision request_push recover_attempt select_lesson)
             )
  end

  test "a second BEAM runtime fails command writer startup", ctx do
    script =
      "Process.flag(:trap_exit, true); IO.inspect(R5eRecurse.Commands.start_link(origin: #{inspect(ctx.origin)}, store: {Unused, nil}))"

    ebin = :code.which(Commands) |> List.to_string() |> Path.dirname()
    assert {output, 0} = System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script])
    assert output =~ "{:error, :writer_ownership_unavailable}"
  end

  test "operator helper signs exact PAE bytes and verifies externally returned signature", ctx do
    message = DSSE.pae("test/type", "payload")
    signature = :crypto.sign(:eddsa, :none, message, [ctx.private, :ed25519])

    script =
      "import sys; op=sys.argv[-1]; " <>
        "assert op=='public-key' or sys.stdin.readline().strip()=='#{Base.encode16(message, case: :lower)}'; " <>
        "print('#{Base.encode16(ctx.public)}' if op=='public-key' else '#{Base.encode16(signature)}')"

    assert {:ok, ^signature} =
             OperatorSignature.sign(
               [
                 command: [System.find_executable("python3"), "-c", script],
                 public_key: ctx.public
               ],
               message
             )
  end

  test "operator envelope uses pinned actor and exact request bytes", ctx do
    command = command(ctx, %{"operation" => "record_decision"})
    envelope = signed(ctx, command)
    payload = Base.decode64!(envelope["payload"])
    request = Jason.decode!(payload)
    message = DSSE.pae(envelope["payloadType"], payload)
    signature = envelope["signatures"] |> hd() |> Map.fetch!("sig") |> Base.decode64!()

    script =
      "import sys; op=sys.argv[-1]; " <>
        "assert op=='public-key' or sys.stdin.readline().strip()=='#{Base.encode16(message, case: :lower)}'; " <>
        "print('#{Base.encode16(ctx.public)}' if op=='public-key' else '#{Base.encode16(signature)}')"

    opts = [command: [System.find_executable("python3"), "-c", script], public_key: ctx.public]
    assert {:ok, ^envelope} = OperatorSignature.envelope(opts, request)

    assert {:error, :invalid_operator_request} =
             OperatorSignature.envelope(opts, Map.put(request, "actor", "service-key"))

    assert {:accepted, _} = Commands.submit(ctx.server, command, envelope)
  end

  defp canonical_record(ctx, command, envelope, outcome, reason, overrides \\ %{}) do
    request = envelope["payload"] |> Base.decode64!() |> Jason.decode!()
    {:ok, spec} = Commands.command_spec(command, caller(ctx))

    payload =
      Map.merge(
        %{
          "identity" => "signed",
          "signed" => envelope,
          "actor" => %{"id" => caller(ctx)},
          "origin" => request["origin"],
          "nonce" => request["nonce"],
          "submittedTarget" => request["target"],
          "target" => Envelope.target(),
          "spec" => spec,
          "outcome" => outcome,
          "reason" => reason
        },
        overrides
      )

    %{event: %{"hash" => Canonical.hash(payload)}, payload: payload}
  end

  test "prefixed authentication denials cannot poison semantic command identity", ctx do
    original = command(ctx, %{"command_id" => "original"})
    victim = command(ctx, %{"command_id" => "victim"})
    envelope = signed(ctx, original)
    {:ok, victim_spec} = Commands.command_spec(victim, caller(ctx))

    for reason <- [
          "authenticate: nonce replayed: this chain has already recorded this nonce from this signer; use a fresh nonce",
          "authenticate: actor mismatch: the request names another actor, signer 1 differs",
          "authenticate: origin mismatch: another chain"
        ] do
      record =
        canonical_record(ctx, original, envelope, "denied", reason, %{"spec" => victim_spec})

      assert {:ok, index} = R5eRecurse.Commands.Dedup.rebuild([record], ctx.origin)
      assert index.commands == %{}
      assert index.denials == %{}
    end

    # Even a post-authentication denial is not evidence for unbound body bytes.
    record =
      canonical_record(
        ctx,
        original,
        envelope,
        "denied",
        "validateStructure: specAddress mismatch",
        %{"spec" => victim_spec}
      )

    assert {:ok, %{denials: denials}} = R5eRecurse.Commands.Dedup.rebuild([record], ctx.origin)
    assert denials == %{}
    malformed = put_in(record.payload["actor"]["id"], "unbound-actor")

    assert {:error, :malformed_signed_history} =
             R5eRecurse.Commands.Dedup.rebuild([malformed], ctx.origin)
  end

  test "wrong-origin denial consumes chain-wide nonce and replay remains a recorded denial",
       ctx do
    command = command(ctx)
    assert {:accepted, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    other_chain = %{ctx | origin: Canonical.hash("another chain")}
    wrong_command = command(other_chain)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))
    wrong_envelope = signed(other_chain, wrong_command, nonce)

    record =
      canonical_record(
        other_chain,
        wrong_command,
        wrong_envelope,
        "denied",
        "authenticate: origin mismatch: the request names another chain"
      )

    Agent.update(ctx.store, fn state ->
      %{
        state
        | records: state.records ++ [record],
          nonces: MapSet.put(state.nonces, {caller(ctx), nonce})
      }
    end)

    assert {:denied, %{"recorded" => true}} =
             Commands.submit(ctx.server, command, signed(ctx, command, nonce))

    assert {:existing, %{outcome: "admitted"}} =
             Commands.lookup(ctx.server, caller(ctx), "stable")

    assert Agent.get(ctx.store, & &1.submissions) == 2
  end

  test "actual isolated-kernel authentication receipts preserve only bound semantics" do
    fixture =
      File.read!(Path.expand("../fixtures/commands/authentication-denials.json", __DIR__))
      |> Jason.decode!()

    records =
      for name <- ~w(original replay actor_mismatch wrong_origin) do
        record = fixture[name]
        assert RecurseVerify.Chain.recompute_hash(record["event"]) == record["event"]["hash"]

        assert Canonical.hash(record["payload"]) ==
                 String.replace_prefix(record["event"]["payload"], "bytes:", "")

        %{event: record["event"], payload: record["payload"]}
      end

    assert {:ok, index} = R5eRecurse.Commands.Dedup.rebuild(records, fixture["origin"])
    actor = fixture["original"]["payload"]["actor"]["id"]
    assert Map.has_key?(index.denials, {actor, "fixture-original"})
    refute Map.has_key?(index.denials, {actor, "fixture-victim"})
    assert MapSet.member?(index.nonces, {actor, fixture["original"]["payload"]["nonce"]})
    assert MapSet.member?(index.nonces, {actor, fixture["wrong_origin"]["payload"]["nonce"]})
    refute MapSet.member?(index.nonces, {actor, fixture["actor_mismatch"]["payload"]["nonce"]})
    assert map_size(index.denials) == 1
  end

  test "operator helper refuses invalid signature, wrong key, oversized output and timeout",
       ctx do
    python = System.find_executable("python3")

    public_script =
      "import sys; print('" <>
        Base.encode16(ctx.public) <> "' if sys.argv[-1]=='public-key' else '00'*64)"

    opts = [command: [python, "-c", public_script], public_key: ctx.public]
    assert {:error, :operator_signature_invalid} = OperatorSignature.sign(opts, "PAE bytes")

    assert {:error, :operator_signature_invalid} =
             OperatorSignature.sign(Keyword.put(opts, :public_key, <<0::256>>), "PAE bytes")

    assert {:error, _} = OperatorSignature.public_key(command: [python, "-c", "print('x'*10000)"])
    started = System.monotonic_time(:millisecond)

    assert {:error, _} =
             OperatorSignature.public_key(
               command: [python, "-c", "import time; time.sleep(5)"],
               timeout: 50
             )

    assert System.monotonic_time(:millisecond) - started < 1500
  end
end
