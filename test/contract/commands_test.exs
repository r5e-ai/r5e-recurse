defmodule R5eRecurse.CommandsTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.Commands
  alias R5eRecurse.Commands.{Envelope, OperatorSignature}
  alias RecurseVerify.{Canonical, DSSE}

  defmodule StoreFixture do
    # Explicit contract fixture, not an isolated-kernel acceptance test.
    def history(%{pid: pid}) do
      {records, barrier, failure} =
        Agent.get_and_update(pid, fn state ->
          {{state.records, state[:history_barrier], state[:history_failure]},
           Map.delete(state, :history_barrier)}
        end)

      if barrier do
        {owner, ref} = barrier
        send(owner, {:history_paused, self(), ref})
        receive do: ({:release_history, ^ref} -> :ok)
      end

      if failure, do: {:error, :fixture_history_unavailable}, else: {:ok, records}
    end

    def client(%{client: client}), do: client

    def prepare_submit(%{client: client}, spec, envelope),
      do: R5eRecurse.Commands.KernelStore.prepare_submit(client, spec, envelope)

    def record(pid, spec, envelope) do
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

        receipt = %{
          "seq" => seq,
          "event" => hash,
          "eventRef" => "event:" <> hash,
          "outcome" => outcome,
          "recorded" => true,
          "identity" => "signed"
        }

        response =
          cond do
            replay and state.mode == :replay_drop -> {:outcome_unknown, :connection_lost}
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

  defmodule HTTPFixture do
    @behaviour Plug
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"spec" => spec, "envelope" => envelope, "name" => nil} = Jason.decode!(body)
      true = conn.method == "POST"
      true = conn.request_path == "/apis/recurse.r5e.io/v1alpha1/Command"

      result = StoreFixture.record(pid, spec, envelope)

      if barrier = Agent.get(pid, & &1[:ack_barrier]) do
        {owner, ref} = barrier
        send(owner, {:ack_paused, self(), ref})
        receive do: ({:release_ack, ^ref} -> :ok)
      end

      case result do
        {:ok, receipt} ->
          Plug.Conn.send_resp(conn, 201, Jason.encode!(receipt))

        {:denied, receipt} ->
          Plug.Conn.send_resp(conn, 403, Jason.encode!(receipt))

        {:outcome_unknown, _} ->
          # Corrupt the wire acknowledgement after recording. The client cannot
          # infer admission from this response; canonical history remains separate.
          Plug.Conn.send_resp(conn, 201, "incomplete acknowledgement")
      end
    end
  end

  setup do
    origin = Canonical.hash(:crypto.strong_rand_bytes(16) |> Base.encode64())
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, store} =
      Agent.start_link(fn ->
        %{records: [], nonces: MapSet.new(), submissions: 0, mode: :normal}
      end)

    {:ok, http} = Bandit.start_link(plug: {HTTPFixture, store}, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(http)
    client = R5eRecurse.KernelClient.new("http://127.0.0.1:#{port}")

    opts = [
      origin: origin,
      store: {StoreFixture, %{pid: store, client: client}},
      operator_keys: [public]
    ]

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

    script = """
    import fcntl, os, sys
    fd = os.open(sys.argv[1] + '/writer.lock', os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('busy')
        sys.exit(3)
    sys.exit(0)
    """

    assert {"busy\n", 3} = System.cmd("python3", ["-c", script, directory])

    assert Enum.sort(Commands.operations()) ==
             Enum.sort(
               ~w(submit_task start_session cancel_session record_decision request_push recover_attempt select_lesson)
             )
  end

  test "a second BEAM runtime fails command writer startup", ctx do
    script =
      "Process.flag(:trap_exit, true); IO.inspect(R5eRecurse.Commands.start_link(origin: #{inspect(ctx.origin)}, store: {R5eRecurse.Commands.KernelStore, R5eRecurse.KernelClient.new(\"http://127.0.0.1:1\")}))"

    ebin = :code.which(Commands) |> List.to_string() |> Path.dirname()
    assert {output, 0} = System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script])
    assert output =~ "{:error, :writer_ownership_unavailable}"
  end

  test "lost replay acknowledgements retain distinct attempts without changing semantic history",
       ctx do
    command = command(ctx)
    envelope = signed(ctx, command)
    assert {:accepted, original} = Commands.submit(ctx.server, command, envelope)
    Agent.update(ctx.store, &%{&1 | mode: :replay_drop})

    assert {:outcome_unknown, %{attempt_id: first}} =
             Commands.submit(ctx.server, command, envelope)

    assert {:outcome_unknown, %{attempt_id: second}} =
             Commands.submit(ctx.server, command, envelope)

    assert first != second
    directory = "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(ctx.origin, "sha256:", "")

    for attempt <- [first, second] do
      record =
        File.read!(Path.join([directory, "replay-v1", attempt <> ".json"])) |> Jason.decode!()

      assert record["attempt_id"] == attempt
      assert record["origin"] == ctx.origin
    end

    assert {:existing, ^original} = Commands.lookup(ctx.server, caller(ctx), "stable")
    assert Agent.get(ctx.store, & &1.submissions) == 3
    GenServer.stop(ctx.server)
    {:ok, restarted} = Commands.start_link(ctx.opts)
    assert {:existing, ^original} = Commands.lookup(restarted, caller(ctx), "stable")
    assert Agent.get(ctx.store, & &1.submissions) == 3
    assert length(Path.wildcard(Path.join([directory, "replay-v1", "*.json"]))) == 2
    GenServer.stop(restarted)
  end

  test "hard broker death preserves the caller's published replay attempt identity", ctx do
    command = command(ctx)
    envelope = signed(ctx, command)
    assert {:accepted, _} = Commands.submit(ctx.server, command, envelope)
    owner = self()
    barrier = make_ref()
    Agent.update(ctx.store, &Map.put(&1, :ack_barrier, {owner, barrier}))
    %{broker: broker, lifetime: lifetime} = :sys.get_state(ctx.server)
    client = ctx.opts |> Keyword.fetch!(:store) |> elem(1) |> Map.fetch!(:client)
    {:ok, spec} = Commands.command_spec(command, caller(ctx))
    {:ok, descriptor} = R5eRecurse.Commands.KernelStore.prepare_submit(client, spec, envelope)
    Process.unlink(ctx.server)

    pending =
      Task.async(fn ->
        R5eRecurse.Commands.Ownership.dispatch(broker, lifetime, :replay, descriptor)
      end)

    assert_receive {:ack_paused, http, ^barrier}, 2000

    try do
      Process.exit(broker, :kill)
      assert {:outcome_unknown, %{attempt_id: attempt}} = Task.await(pending, 2000)

      directory =
        "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(ctx.origin, "sha256:", "")

      record =
        File.read!(Path.join([directory, "replay-v1", attempt <> ".json"])) |> Jason.decode!()

      assert record["attempt_id"] == attempt
      assert record["origin"] == ctx.origin
      assert Agent.get(ctx.store, & &1.submissions) == 2
    after
      send(http, {:release_ack, barrier})
    end
  end

  test "lost finalize acknowledgement returns uncertainty with the known admission", ctx do
    command = command(ctx)
    owner = self()
    barrier = make_ref()
    Agent.update(ctx.store, &Map.put(&1, :ack_barrier, {owner, barrier}))
    %{broker: broker} = :sys.get_state(ctx.server)
    %{port: port} = :sys.get_state(broker)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    pending = Task.async(fn -> Commands.submit(ctx.server, command, signed(ctx, command)) end)
    assert_receive {:ack_paused, http, ^barrier}, 2000

    try do
      :ok = :sys.suspend(broker)
      send(http, {:release_ack, barrier})
      wait_for_message(broker, port, System.monotonic_time(:millisecond) + 800)

      assert {_, 0} =
               System.cmd("python3", [
                 "-c",
                 "import os,signal,sys; os.kill(int(sys.argv[1]), signal.SIGSTOP)",
                 Integer.to_string(os_pid)
               ])

      :ok = :sys.resume(broker)

      assert {:outcome_unknown,
              %{reason: :finalization_failed, known_outcome: {:accepted, known}}} =
               Task.await(pending, 3000)

      assert known.outcome == "admitted"
      assert {:existing, ^known} = Commands.lookup(ctx.server, caller(ctx), "stable")
      assert Agent.get(ctx.store, & &1.submissions) == 1
    after
      send(http, {:release_ack, barrier})
      if Process.alive?(broker), do: :sys.resume(broker)

      System.cmd("python3", [
        "-c",
        "import os,signal,sys\ntry: os.kill(int(sys.argv[1]), signal.SIGCONT)\nexcept ProcessLookupError: pass",
        Integer.to_string(os_pid)
      ])
    end
  end

  defp wait_for_message(broker, port, deadline) do
    {:messages, messages} = Process.info(broker, :messages)

    if Enum.any?(messages, fn
         {^port, {:data, _}} -> true
         _ -> false
       end) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "helper did not return its receipt before finalize deadline"

      Process.sleep(5)
      wait_for_message(broker, port, deadline)
    end
  end

  test "unavailable canonical history stays unknown and never dispatches", ctx do
    Agent.update(ctx.store, &Map.put(&1, :history_failure, true))
    command = command(ctx)
    assert {:outcome_unknown, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    assert Agent.get(ctx.store, & &1.submissions) == 0
  end

  test "partial legacy pending marker is unresolved rather than a payload conflict", ctx do
    command = command(ctx)
    {:ok, spec} = Commands.command_spec(command, caller(ctx))
    directory = "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(ctx.origin, "sha256:", "")
    path = Path.join(directory, Canonical.hash([caller(ctx), spec["commandId"]]) <> ".pending")
    File.write!(path, "sha256:incomplete")
    assert {:outcome_unknown, _} = Commands.submit(ctx.server, command, signed(ctx, command))
    assert File.read!(path) == "sha256:incomplete"
    assert Agent.get(ctx.store, & &1.submissions) == 0
  end

  for mode <- [:normal, :replay] do
    @dispatch_mode mode
    test "helper loss fences paused #{@dispatch_mode} dispatch after replacement acquisition",
         ctx do
      mode = @dispatch_mode
      command = command(ctx)
      envelope = signed(ctx, command)

      if mode == :replay,
        do: assert({:accepted, _} = Commands.submit(ctx.server, command, envelope))

      baseline = Agent.get(ctx.store, & &1.submissions)
      %{broker: broker} = :sys.get_state(ctx.server)
      %{port: port} = :sys.get_state(broker)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      port_monitor = Port.monitor(port)
      Process.unlink(ctx.server)
      barrier = make_ref()
      owner = self()
      Agent.update(ctx.store, &Map.put(&1, :history_barrier, {owner, barrier}))

      pending =
        Task.async(fn ->
          try do
            Commands.submit(ctx.server, command, envelope)
          catch
            :exit, reason -> {:owner_exited, reason}
          end
        end)

      assert_receive {:history_paused, callback, ^barrier}

      replacement =
        try do
          assert {_, 0} =
                   System.cmd("python3", [
                     "-c",
                     "import os,signal,sys; os.kill(int(sys.argv[1]), signal.SIGKILL)",
                     Integer.to_string(os_pid)
                   ])

          assert_receive {:DOWN, ^port_monitor, :port, ^port, _}, 2000
          {:ok, replacement} = Commands.start_link(ctx.opts)
          replacement
        after
          send(callback, {:release_history, barrier})
        end

      assert {tag, _} = Task.await(pending, 2000)
      assert tag in [:owner_exited, :outcome_unknown]
      assert Agent.get(ctx.store, & &1.submissions) == baseline
      GenServer.stop(replacement)
    end
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
