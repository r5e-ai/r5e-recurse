defmodule R5eRecurse.SignerTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.{SessionKeys, Signer, Signer.Channel, Authority.Kinds, Commands.Envelope}
  alias RecurseVerify.{Canonical, Chain, DSSE}
  @now ~U[2030-01-01 12:00:00Z]
  @origin "sha256:" <> String.duplicate("a", 64)
  @task "event:sha256:" <> String.duplicate("b", 64)
  @kind "gateway.r5e.io/v1alpha1/Prompt"

  setup do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "session", self())
    actor = DSSE.key_id!("ed25519", key.public_key)
    {snapshot, refs, roots} = credentials(keys, key, actor)
    body = "{\"input\":\"hello\"}"

    target = %{
      "group" => "gateway.r5e.io",
      "version" => "v1alpha1",
      "kind" => "Prompt",
      "name" => nil
    }

    spec = %{
      "session" => %{"$ref" => "gateway.r5e.io/v1alpha1/AgentSession/session"},
      "contentRef" => %{"$ref" => "bytes:" <> Canonical.hash_bytes(body)}
    }

    authority = [refs.badge, refs.delegation]

    context = %{
      request: %{
        actor: actor,
        role: :producer,
        authority: authority,
        targets: %{@kind => target},
        span: spec["session"]["$ref"],
        body: body,
        read_bytes: fn _ -> {:ok, body} end
      },
      authority: %{
        actor: actor,
        role: :producer,
        authority: authority,
        origin: @origin,
        task: @task,
        kind: @kind,
        refs: refs,
        roots: roots,
        max_snapshot_age_seconds: 5
      }
    }

    parent = self()

    callback = fn _ ->
      send(parent, :snapshot_read)
      {:ok, snapshot}
    end

    signer = service(keys, callback)

    %{
      keys: keys,
      generation: key.generation,
      public: key.public_key,
      actor: actor,
      context: context,
      snapshot: snapshot,
      signer: signer,
      wire: %{"kind" => @kind, "specBytes" => Canonical.encode(spec), "authority" => authority}
    }
  end

  test "real key produces canonical eight-field envelope with generated nonce and capped expiry",
       c do
    {:ok, slot} = register(c)
    assert {:ok, envelope} = Signer.sign(c.signer, slot, c.wire)
    assert_receive :snapshot_read
    assert {:ok, verified} = Envelope.verify_signed(envelope)
    request = verified.request

    assert Enum.sort(Map.keys(request)) ==
             Enum.sort(~w(origin actor target specAddress derivedFrom authority nonce expires))

    assert request["origin"] == @origin and request["actor"] == c.actor
    assert request["specAddress"] == Canonical.hash(Jason.decode!(c.wire["specBytes"]))
    assert request["authority"] == c.context.authority.authority
    assert request["expires"] == "2030-01-01T12:05:00Z"
    assert {:ok, nonce} = DSSE.decode64(request["nonce"])
    assert byte_size(nonce) == 16
    assert {:ok, bytes, actor} = DSSE.verify(envelope, c.public)
    assert actor == c.actor and bytes == Canonical.encode(request)
    assert {:error, :operation_consumed} = Signer.sign(c.signer, slot, c.wire)
    refute_receive :snapshot_read, 0
    refute Map.has_key?(:sys.get_state(c.signer).slots[slot], :context)
  end

  test "wire extras refuse and consume attempts without minting or falling back", c do
    for field <- ~w(actor origin expires nonce specAddress target generation) do
      {:ok, slot} = register(c, field)

      assert {:error, :signer_refused} =
               Signer.sign(c.signer, slot, Map.put(c.wire, field, "forged"))

      assert {:error, :operation_consumed} = Signer.sign(c.signer, slot, c.wire)
    end

    refute_receive :snapshot_read, 0
  end

  test "operation registration is immutable and concurrent repeats cannot sign twice", c do
    {:ok, slot} = register(c)
    assert {:error, :operation_registered} = register(c)

    assert {:error, :operation_registered} =
             Signer.register(
               c.signer,
               self(),
               c.generation,
               "op",
               put_in(c.context, [:request, :body], "changed")
             )

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> Signer.sign(c.signer, slot, c.wire) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :operation_consumed})) == 1
    assert_receive :snapshot_read
    refute_receive :snapshot_read, 0
  end

  test "stale generation and wrong registered actor or owner refuse", c do
    assert {:error, :invalid_registration} =
             Signer.register(
               c.signer,
               self(),
               %{"bootId" => "old", "runId" => "old"},
               "op",
               c.context
             )

    wrong = put_in(c.context, [:request, :actor], "other")

    assert {:error, :invalid_registration} =
             Signer.register(c.signer, self(), c.generation, "op", wrong)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)

    assert {:error, :invalid_registration} =
             Signer.register(c.signer, owner, c.generation, "op", c.context)
  end

  test "key death during snapshot acquisition refuses and consumes operation", c do
    # Bind this generation only to the alternate service used in this test.
    signer =
      service(c.keys, fn _ ->
        SessionKeys.destroy(c.keys, c.generation)
        {:ok, c.snapshot}
      end)

    {:ok, slot} = Signer.register(signer, self(), c.generation, "op", c.context)
    assert {:error, :signer_refused} = Signer.sign(signer, slot, c.wire)
    assert {:error, :invalid_binding} = Signer.sign(signer, slot, c.wire)
    assert {:error, _} = SessionKeys.public_key(c.keys, c.generation)
  end

  test "reader outage consumes operation without fallback", c do
    signer = service(c.keys, fn _ -> exit(:reader_down) end)
    {:ok, slot} = Signer.register(signer, self(), c.generation, "op", c.context)
    assert {:error, :signer_refused} = Signer.sign(signer, slot, c.wire)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
  end

  test "key service outage refuses without a replacement signer", c do
    {:ok, slot} = register(c)
    Process.exit(c.keys, :kill)
    assert {:error, reason} = Signer.sign(c.signer, slot, c.wire)
    assert reason in [:signer_refused, :invalid_binding]
    assert {:error, :invalid_binding} = Signer.sign(c.signer, slot, c.wire)
  end

  test "signer death synchronously fences generation even without a delivered DOWN", c do
    {:ok, _slot} = register(c)
    # Suppress monitor delivery to expose the exact pre-DOWN liveness window.
    :sys.replace_state(c.keys, fn state ->
      Process.demonitor(state.keys[c.generation].signer_monitor, [:flush])
      state
    end)

    down = Process.monitor(c.signer)
    Process.exit(c.signer, :kill)
    assert_receive {:DOWN, ^down, :process, _, :killed}
    replacement = service(c.keys, fn _ -> {:ok, c.snapshot} end)

    assert {:error, :invalid_registration} =
             Signer.register(replacement, self(), c.generation, "op", c.context)

    assert {:error, _} = SessionKeys.public_key(c.keys, c.generation)
    assert {:error, _} = SessionKeys.sign(c.keys, c.generation, "opaque")
  end

  test "another living signer cannot bind a generation already guarded", c do
    {:ok, _} = register(c)
    replacement = service(c.keys, fn _ -> {:ok, c.snapshot} end)

    assert {:error, :invalid_registration} =
             Signer.register(replacement, self(), c.generation, "other", c.context)
  end

  test "unsupported Review cannot enter the signing path", c do
    {:ok, slot} = register(c)

    assert {:error, :signer_refused} =
             Signer.sign(c.signer, slot, %{c.wire | "kind" => "recurse.r5e.io/v1alpha1/Review"})

    refute_receive :snapshot_read, 0
  end

  test "actual Channel authenticates and adapter binds generation and consumed slot", c do
    {:ok, slot} = register(c)
    directory = Path.join(System.tmp_dir!(), "signer-live-#{System.unique_integer([:positive])}")

    channel =
      start_supervised!(
        {Channel, keys: c.keys, directory: directory, handler: Signer.channel_handler(c.signer)}
      )

    {:ok, route} = Channel.register(channel, self(), c.generation, %{slot: slot})
    provision = Channel.provision(channel)

    message = %{
      "secret" => provision.secret,
      "route" => route.route,
      "credential" => route.credential,
      "generation" => route.generation,
      "operation" => "authenticate",
      "request" => %{}
    }

    assert %{"ok" => true} = wire(provision.path, message)

    assert %{"ok" => envelope} =
             wire(provision.path, %{message | "operation" => "sign", "request" => c.wire})

    assert {:ok, _} = Envelope.verify_signed(envelope)

    assert %{"error" => "signer_refused"} =
             wire(provision.path, %{message | "operation" => "sign", "request" => c.wire})

    {:ok, other_slot} = register(c, "other")
    handler = Signer.channel_handler(c.signer)
    assert {:error, :invalid_binding} = handler.(%{slot: other_slot, generation: %{}}, c.wire)
    assert {:ok, _} = Signer.sign(c.signer, other_slot, c.wire)
  end

  test "owner death fences an already registered slot", c do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    {:ok, key} = SessionKeys.create(c.keys, "owned-session", owner)
    actor = DSSE.key_id!("ed25519", key.public_key)
    {snapshot, refs, roots} = credentials(c.keys, key, actor)
    authority = [refs.badge, refs.delegation]

    context = %{
      request: %{c.context.request | actor: actor, authority: authority},
      authority: %{
        c.context.authority
        | actor: actor,
          authority: authority,
          refs: refs,
          roots: roots
      }
    }

    signer = service(c.keys, fn _ -> {:ok, snapshot} end)
    {:ok, slot} = Signer.register(signer, owner, key.generation, "op", context)
    down = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^down, :process, ^owner, :killed}
    assert {:error, reason} = Signer.sign(signer, slot, %{c.wire | "authority" => authority})
    assert reason in [:invalid_binding, :signer_refused]
    assert {:error, _} = SessionKeys.public_key(c.keys, key.generation)
    # Flush the actual known monitor's DOWN deterministically if it has not yet
    # been processed; this does not rely on sleeping for cross-process delivery.
    state = :sys.get_state(signer)

    if entry = state.slots[slot],
      do: send(signer, {:DOWN, entry.monitor, :process, owner, :killed})

    state = :sys.get_state(signer)
    assert state.slots == %{}
    assert MapSet.size(state.operations) == 0

    assert {:error, :invalid_registration} =
             Signer.register(signer, owner, key.generation, "op", context)
  end

  test "signer outage is a bounded refusal", c do
    {:ok, slot} = register(c)
    down = Process.monitor(c.signer)
    Process.exit(c.signer, :kill)
    assert_receive {:DOWN, ^down, :process, _, :killed}
    assert {:error, :signer_unavailable} = Signer.sign(c.signer, slot, c.wire)
  end

  test "clock is sampled after snapshot acquisition and each new operation reads afresh", c do
    clock = start_supervised!({Agent, fn -> @now end})
    parent = self()

    snapshot = fn before_read ->
      after_read = DateTime.add(before_read, 1, :second)
      Agent.update(clock, fn _ -> after_read end)
      send(parent, :fresh_read)
      {:ok, %{c.snapshot | observed_at: after_read}}
    end

    signer =
      start_supervised!(
        {Signer, keys: c.keys, snapshot: snapshot, clock: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    for n <- 1..2 do
      {:ok, slot} = Signer.register(signer, self(), c.generation, "fresh-#{n}", c.context)
      assert {:ok, envelope} = Signer.sign(signer, slot, c.wire)
      assert {:ok, verified} = Envelope.verify_signed(envelope)

      assert verified.request["expires"] ==
               DateTime.to_iso8601(DateTime.add(@now, 300 + n, :second))

      assert_receive :fresh_read
    end
  end

  test "one HTTP operation registers separate Kind slots but each Kind is immutable", c do
    assert {:ok, _} = register(c)
    call_context = put_in(c.context, [:authority, :kind], "gateway.r5e.io/v1alpha1/LlmCall")
    assert {:ok, _} = Signer.register(c.signer, self(), c.generation, "op", call_context)

    assert {:error, :operation_registered} =
             Signer.register(c.signer, self(), c.generation, "op", call_context)

    managed =
      c.context
      |> put_in([:authority, :kind], "recurse.r5e.io/v1alpha1/ManagedRequest")
      |> put_in([:request, :managed], %{"operationId" => "op"})

    assert {:error, :invalid_registration} =
             Signer.register(c.signer, self(), c.generation, "different", managed)

    assert {:ok, _} = Signer.register(c.signer, self(), c.generation, "op", managed)

    assert {:error, :operation_registered} =
             Signer.register(c.signer, self(), c.generation, "op", managed)

    assert {:error, :invalid_registration} =
             Signer.register(c.signer, self(), c.generation, "invalid", nil)
  end

  test "deadline kills a blocked preflight; releasing it after refusal cannot sign", c do
    parent = self()

    callback = fn _ ->
      send(parent, {:blocked_preflight, self()})

      receive do
        :release -> {:ok, c.snapshot}
      end
    end

    signer =
      start_supervised!(
        {Signer,
         keys: c.keys, snapshot: callback, clock: fn -> @now end, attempt_timeout_ms: 100},
        id: make_ref()
      )

    {:ok, slot} = Signer.register(signer, self(), c.generation, "bounded", c.context)
    trace_signs(c.keys)
    caller = Task.async(fn -> Signer.sign(signer, slot, c.wire) end)
    assert_receive {:blocked_preflight, worker}
    monitor = Process.monitor(worker)
    assert {:error, :signer_refused} = Task.await(caller)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    send(worker, :release)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
    refute_receive {:trace, _, :call, {:crypto, :sign, 4}}, 0
    assert {:ok, _} = Signer.register(signer, self(), c.generation, "another", c.context)
  end

  test "queued key signing refuses expired credential after resume", c do
    {signer, slot, clock, caller} = queued_sign(c, 2_000)
    Agent.update(clock, &%{&1 | now: DateTime.add(@now, 301, :second)})
    :sys.resume(c.keys)
    assert {:error, :signer_refused} = Task.await(caller)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
    refute_receive {:trace, _, :call, {:crypto, :sign, 4}}, 0
  end

  test "queued key request remains fenced after attempt deadline and caller refusal", c do
    {signer, slot, _clock, caller} = queued_sign(c, 100)
    assert {:error, :signer_refused} = Task.await(caller)
    :sys.resume(c.keys)
    # A synchronous call is a barrier after the previously queued signing request.
    assert {:ok, _} = SessionKeys.public_key(c.keys, c.generation)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
    refute_receive {:trace, _, :call, {:crypto, :sign, 4}}, 0
  end

  test "snapshot age is checked again after authority validation", c do
    clock = start_supervised!({Agent, fn -> 0 end})

    sample = fn ->
      Agent.get_and_update(clock, fn n ->
        {if(n < 2, do: @now, else: DateTime.add(@now, 6, :second)), n + 1}
      end)
    end

    signer =
      start_supervised!(
        {Signer, keys: c.keys, snapshot: fn _ -> {:ok, c.snapshot} end, clock: sample},
        id: make_ref()
      )

    {:ok, slot} = Signer.register(signer, self(), c.generation, "age", c.context)
    trace_signs(c.keys)
    assert {:error, :signer_refused} = Signer.sign(signer, slot, c.wire)
    refute_receive {:trace, _, :call, {:crypto, :sign, 4}}, 0
  end

  test "expired queued signer job consumes slot without running callbacks", c do
    {:ok, slot} = register(c)
    expired = System.monotonic_time(:millisecond) - 1
    handler = Signer.channel_handler(c.signer)

    assert {:error, :signer_refused} =
             handler.(%{slot: slot, generation: c.generation, deadline: expired}, c.wire)

    refute_receive :snapshot_read, 0
    assert {:error, :operation_consumed} = Signer.sign(c.signer, slot, c.wire)
  end

  test "blocked keys cannot retain a registration past its deadline", c do
    signer =
      start_supervised!(
        {Signer,
         keys: c.keys,
         snapshot: fn _ -> {:ok, c.snapshot} end,
         clock: fn -> @now end,
         attempt_timeout_ms: 50},
        id: make_ref()
      )

    :sys.suspend(c.keys)
    on_exit(fn -> if Process.alive?(c.keys), do: :sys.resume(c.keys) end)

    assert {:error, :invalid_registration} =
             Signer.register(signer, self(), c.generation, "late", c.context)

    :sys.resume(c.keys)
    assert {:ok, _} = SessionKeys.public_key(c.keys, c.generation)
    assert :sys.get_state(c.keys).keys[c.generation].signer == nil
    assert {:ok, _} = Signer.register(signer, self(), c.generation, "late", c.context)
  end

  test "expiry crossing during the key operation cannot return a successful envelope", c do
    clock = start_supervised!({Agent, fn -> 0 end})

    sample = fn ->
      Agent.get_and_update(clock, fn count ->
        {if(count < 4, do: @now, else: DateTime.add(@now, 301, :second)), count + 1}
      end)
    end

    signer =
      start_supervised!(
        {Signer, keys: c.keys, snapshot: fn _ -> {:ok, c.snapshot} end, clock: sample},
        id: make_ref()
      )

    context = put_in(c.context, [:authority, :max_snapshot_age_seconds], 1_000)
    {:ok, slot} = Signer.register(signer, self(), c.generation, "cross-expiry", context)
    trace_signs(c.keys)
    assert {:error, :signer_refused} = Signer.sign(signer, slot, c.wire)
    keys = c.keys
    assert_receive {:trace, ^keys, :call, {:crypto, :sign, 4}}
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
  end

  test "actual Channel permits exactly 1 MiB decoded spec and signer refuses one byte over", c do
    directory = Path.join(System.tmp_dir!(), "signer-size-#{System.unique_integer([:positive])}")

    channel =
      start_supervised!(
        {Channel, keys: c.keys, directory: directory, handler: Signer.channel_handler(c.signer)}
      )

    provision = Channel.provision(channel)

    spec =
      c.wire["specBytes"] <> String.duplicate("\t", 1_048_576 - byte_size(c.wire["specBytes"]))

    assert byte_size(spec) == 1_048_576

    for {id, bytes, expected} <- [{"maximum", spec, :ok}, {"oversize", spec <> " ", :error}] do
      {:ok, slot} = register(c, id)
      {:ok, route} = Channel.register(channel, self(), c.generation, %{slot: slot})

      message = %{
        "secret" => provision.secret,
        "route" => route.route,
        "credential" => route.credential,
        "generation" => route.generation,
        "operation" => "authenticate",
        "request" => %{}
      }

      assert %{"ok" => true} = wire(provision.path, message)

      result =
        wire(provision.path, %{
          message
          | "operation" => "sign",
            "request" => %{c.wire | "specBytes" => bytes}
        })

      case expected do
        :ok -> assert {:ok, _} = Envelope.verify_signed(result["ok"])
        :error -> assert result == %{"error" => "signer_refused"}
      end
    end
  end

  test "bootstrap signing is forbidden after managed registration", c do
    assert {:ok, _} = SessionKeys.sign(c.keys, c.generation, "bootstrap")
    {:ok, slot} = register(c)
    assert {:error, :managed_generation} = SessionKeys.sign(c.keys, c.generation, "bypass")
    assert {:ok, _} = Signer.sign(c.signer, slot, c.wire)
  end

  test "bootstrap request queued behind signer binding cannot bypass managed phase", c do
    parent = self()
    :erlang.trace(c.keys, true, [:receive])
    :sys.suspend(c.keys)
    binder = Task.async(fn -> SessionKeys.bind_signer(c.keys, c.generation, parent) end)
    keys = c.keys
    assert_receive {:trace, ^keys, :receive, {:"$gen_call", _, {:bind_signer, _, ^parent}}}
    caller = Task.async(fn -> SessionKeys.sign(c.keys, c.generation, "queued-bootstrap") end)
    assert_receive {:trace, ^keys, :receive, {:"$gen_call", _, {:sign, _, _}}}
    :sys.resume(c.keys)
    assert :ok = Task.await(binder)
    assert {:error, :managed_generation} = Task.await(caller)
  end

  test "short budget starts at original Channel packet receipt", c do
    parent = self()

    signer =
      start_supervised!(
        {Signer,
         keys: c.keys,
         snapshot: fn _ ->
           send(parent, :unexpected_snapshot)
           {:ok, c.snapshot}
         end,
         attempt_timeout_ms: 30},
        id: make_ref()
      )

    {:ok, slot} = Signer.register(signer, self(), c.generation, "channel-queued", c.context)
    started = System.monotonic_time(:millisecond) - 60
    handler = Signer.channel_handler(signer)

    assert {:error, :signer_refused} =
             handler.(
               %{
                 slot: slot,
                 generation: c.generation,
                 attempt_started_at: started,
                 deadline: started + 4_000
               },
               c.wire
             )

    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
    refute_receive :unexpected_snapshot, 0
  end

  test "short configured budget includes signer queue residence", c do
    parent = self()

    signer =
      start_supervised!(
        {Signer,
         keys: c.keys,
         snapshot: fn _ ->
           send(parent, :unexpected_snapshot)
           {:ok, c.snapshot}
         end,
         attempt_timeout_ms: 30},
        id: make_ref()
      )

    {:ok, slot} = Signer.register(signer, self(), c.generation, "queued", c.context)
    :erlang.trace(signer, true, [:receive])
    :sys.suspend(signer)
    caller = Task.async(fn -> Signer.sign(signer, slot, c.wire) end)
    assert_receive {:trace, ^signer, :receive, {:"$gen_call", _, {:sign, ^slot, _, _, _}}}

    receive do
    after
      60 -> :ok
    end

    :sys.resume(signer)
    assert {:error, :signer_refused} = Task.await(caller)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
    refute_receive :unexpected_snapshot, 0
  end

  test "short registration budget also includes queue residence", c do
    signer =
      start_supervised!(
        {Signer, keys: c.keys, snapshot: fn _ -> {:ok, c.snapshot} end, attempt_timeout_ms: 30},
        id: make_ref()
      )

    :erlang.trace(signer, true, [:receive])
    :sys.suspend(signer)
    parent = self()

    caller =
      Task.async(fn -> Signer.register(signer, parent, c.generation, "late", c.context) end)

    assert_receive {:trace, ^signer, :receive, {:"$gen_call", _, {:register, _, _, _, _, _}}}

    receive do
    after
      60 -> :ok
    end

    :sys.resume(signer)
    assert {:error, :invalid_registration} = Task.await(caller)
    assert :sys.get_state(c.keys).keys[c.generation].signer == nil
  end

  test "final custody release refuses a generation already destroyed", c do
    {:ok, _} = register(c)
    assert :ok = SessionKeys.destroy(c.keys, c.generation)

    validity = %{
      clock: fn -> @now end,
      observed_at: @now,
      max_age_seconds: 30,
      expires: "2030-01-01T12:05:00Z"
    }

    assert {:error, :stale_release} =
             SessionKeys.release_before(
               c.keys,
               c.generation,
               self(),
               c.signer,
               c.public,
               System.monotonic_time(:millisecond) + 1000,
               validity
             )
  end

  test "final custody release refuses owner death during its clock", c do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, key} = SessionKeys.create(c.keys, "release-owner", owner)
    assert :ok = SessionKeys.bind_signer(c.keys, key.generation, self())

    validity = %{
      clock: fn ->
        send(parent, {:release_clock, self()})

        receive do
          :continue -> @now
        end
      end,
      observed_at: @now,
      max_age_seconds: 30,
      expires: "2030-01-01T12:05:00Z"
    }

    caller =
      Task.async(fn ->
        SessionKeys.release_before(
          c.keys,
          key.generation,
          owner,
          parent,
          key.public_key,
          System.monotonic_time(:millisecond) + 1000,
          validity
        )
      end)

    assert_receive {:release_clock, worker}
    monitor = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    send(worker, :continue)
    assert {:error, :stale_release} = Task.await(caller)
  end

  test "explicit retirement clears unused contexts and replay entries with owner alive", c do
    {:ok, _} = register(c)
    assert :ok = SessionKeys.destroy(c.keys, c.generation)
    state = :sys.get_state(c.signer)
    assert state.slots == %{}
    assert MapSet.size(state.operations) == 0

    for index <- 1..3 do
      {:ok, key} = SessionKeys.create(c.keys, "retire-#{index}", self())
      actor = DSSE.key_id!("ed25519", key.public_key)

      context =
        c.context |> put_in([:request, :actor], actor) |> put_in([:authority, :actor], actor)

      assert {:ok, _} = Signer.register(c.signer, self(), key.generation, "cycle", context)
      assert :ok = SessionKeys.destroy(c.keys, key.generation)
      state = :sys.get_state(c.signer)
      assert state.slots == %{}
      assert MapSet.size(state.operations) == 0
    end
  end

  test "custody service death clears pending signer state", c do
    {:ok, _} = register(c)
    GenServer.stop(c.keys)
    state = :sys.get_state(c.signer)
    assert state.slots == %{}
    assert MapSet.size(state.operations) == 0
  end

  test "linked snapshot dependency failure preserves signer and unrelated key", c do
    {:ok, unrelated} = SessionKeys.create(c.keys, "unrelated", self())
    parent = self()

    signer =
      service(c.keys, fn _ ->
        spawn_link(fn -> exit(:reader_dependency_down) end)
        send(parent, :dependency_started)

        receive do
          :never -> {:ok, c.snapshot}
        end
      end)

    {:ok, slot} = Signer.register(signer, self(), c.generation, "dependency", c.context)
    assert {:error, :signer_refused} = Signer.sign(signer, slot, c.wire)
    assert Process.alive?(signer)
    assert {:ok, _} = SessionKeys.public_key(c.keys, c.generation)
    assert {:ok, _} = SessionKeys.public_key(c.keys, unrelated.generation)
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
  end

  test "linked clock failure and timeout races preserve all custody generations", c do
    {:ok, unrelated} = SessionKeys.create(c.keys, "other-clock", self())
    assert :ok = SessionKeys.bind_signer(c.keys, c.generation, self())
    base = %{observed_at: @now, max_age_seconds: 30, expires: "2030-01-01T12:05:00Z"}

    broken =
      Map.put(base, :clock, fn ->
        spawn_link(fn -> exit(:clock_dependency_down) end)

        receive do
          :never -> @now
        end
      end)

    assert {:error, :stale_release} =
             SessionKeys.release_before(
               c.keys,
               c.generation,
               self(),
               self(),
               c.public,
               System.monotonic_time(:millisecond) + 1000,
               broken
             )

    racing =
      Map.put(base, :clock, fn ->
        receive do
        after
          1 -> @now
        end
      end)

    for _ <- 1..3000 do
      SessionKeys.release_before(
        c.keys,
        c.generation,
        self(),
        self(),
        c.public,
        System.monotonic_time(:millisecond) + 2,
        racing
      )
    end

    assert {:ok, _} = SessionKeys.public_key(c.keys, c.generation)
    assert {:ok, _} = SessionKeys.public_key(c.keys, unrelated.generation)
  end

  defp queued_sign(c, timeout) do
    parent = self()
    clock = start_supervised!({Agent, fn -> %{now: @now, calls: 0} end})

    sample = fn ->
      {now, count} =
        Agent.get_and_update(clock, fn state ->
          {{state.now, state.calls}, %{state | calls: state.calls + 1}}
        end)

      if count == 2 do
        send(parent, {:ready_for_keys, self()})

        receive do
          :release -> :ok
        end
      end

      now
    end

    signer =
      start_supervised!(
        {Signer,
         keys: c.keys,
         snapshot: fn _ -> {:ok, c.snapshot} end,
         clock: sample,
         attempt_timeout_ms: timeout},
        id: make_ref()
      )

    context = put_in(c.context, [:authority, :max_snapshot_age_seconds], 1_000)
    {:ok, slot} = Signer.register(signer, self(), c.generation, "queued", context)
    trace_signs(c.keys)
    :erlang.trace(c.keys, true, [:receive])
    caller = Task.async(fn -> Signer.sign(signer, slot, c.wire) end)
    assert_receive {:ready_for_keys, worker}
    :sys.suspend(c.keys)
    on_exit(fn -> if Process.alive?(c.keys), do: :sys.resume(c.keys) end)
    send(worker, :release)
    keys = c.keys

    assert_receive {:trace, ^keys, :receive, {:"$gen_call", _, {:sign_before, _, _, _, _, _, _}}},
                   1_000

    {signer, slot, clock, caller}
  end

  defp trace_signs(keys) do
    :erlang.trace_pattern({:crypto, :sign, 4}, true, [:local])
    :erlang.trace(keys, true, [:call, :arity])
    on_exit(fn -> :erlang.trace_pattern({:crypto, :sign, 4}, false, [:local]) end)
  end

  defp register(c, id \\ "op"), do: Signer.register(c.signer, self(), c.generation, id, c.context)

  defp service(keys, snapshot) do
    start_supervised!({Signer, keys: keys, snapshot: snapshot, clock: fn -> @now end},
      id: make_ref()
    )
  end

  defp wire(path, message) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(path)},
        0,
        [:binary, active: false, packet: 4],
        1000
      )

    :ok = :gen_tcp.send(socket, Jason.encode!(message))
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
    :gen_tcp.close(socket)
    Jason.decode!(bytes)
  end

  defp credentials(keys, key, actor) do
    {issuer_public, issuer_private} = :crypto.generate_key(:eddsa, :ed25519)
    issuer = DSSE.key_id!("ed25519", issuer_public)
    {:ok, kinds} = Kinds.for_role(:producer)

    spec = %{
      "subject" => actor,
      "subjectKey" => %{"algorithm" => "ed25519", "bytes" => Base.encode64(key.public_key)},
      "role" => "producer",
      "scope" => %{"task" => @task},
      "kinds" => kinds,
      "mayIssue" => false,
      "notBefore" => "2030-01-01T11:00:00Z",
      "notAfter" => "2030-01-01T13:00:00Z"
    }

    {records, _} =
      Enum.map_reduce(["Badge", "Endorsement"], Chain.genesis(), fn type, prev ->
        spec = if type == "Badge", do: Map.put(spec, "subjectKind", "agent"), else: spec
        target = %{"group" => "core.r5e.io", "version" => "v1", "kind" => type, "name" => nil}

        request = %{
          "origin" => @origin,
          "actor" => issuer,
          "target" => target,
          "specAddress" => Canonical.hash(spec),
          "derivedFrom" => nil,
          "authority" => [],
          "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
          "expires" => "2030-01-01T12:01:00Z"
        }

        bytes = Canonical.encode(request)
        type_name = "application/vnd.r5e.admission-request+json;v=1"
        pae = DSSE.pae(type_name, bytes)

        signature = %{
          "keyid" => issuer,
          "sig" => Base.encode64(:crypto.sign(:eddsa, :none, pae, [issuer_private, :ed25519]))
        }

        public = %{
          "keyid" => issuer,
          "algorithm" => "ed25519",
          "bytes" => Base.encode64(issuer_public)
        }

        {signatures, public_keys} =
          if type == "Badge" do
            {:ok, signature2} = SessionKeys.sign(keys, key.generation, pae)

            {[signature, %{"keyid" => actor, "sig" => Base.encode64(signature2)}],
             [
               public,
               %{
                 "keyid" => actor,
                 "algorithm" => "ed25519",
                 "bytes" => Base.encode64(key.public_key)
               }
             ]}
          else
            {[signature], [public]}
          end

        signed = %{
          "payloadType" => type_name,
          "payload" => Base.encode64(bytes),
          "signatures" => signatures,
          "publicKeys" => public_keys
        }

        payload =
          Map.drop(request, ["specAddress"])
          |> Map.merge(%{
            "identity" => "signed",
            "signed" => signed,
            "actor" => %{
              "id" => issuer,
              "algorithm" => "ed25519",
              "publicKey" => Base.encode64(issuer_public)
            },
            "submittedTarget" => target,
            "spec" => spec,
            "outcome" => "admitted",
            "depth" => 0
          })

        event = %{
          "seq" => if(type == "Badge", do: 1, else: 2),
          "prev" => prev,
          "kind" => "admission.granted",
          "ts" => "2030-01-01T11:59:50Z",
          "payload" => Canonical.hash(payload)
        }

        event = Map.put(event, "hash", Canonical.hash(event))
        {{event, payload}, event["hash"]}
      end)

    [{badge, _}, {delegation, _}] = records

    snapshot = %{
      origin: @origin,
      complete: true,
      head: %{seq: 2, hash: delegation["hash"]},
      observed_at: @now,
      records: records
    }

    {snapshot, %{badge: "event:" <> badge["hash"], delegation: "event:" <> delegation["hash"]},
     %{badge: issuer, delegation: issuer}}
  end
end
