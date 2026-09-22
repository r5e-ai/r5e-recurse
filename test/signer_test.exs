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
    assert {:error, :operation_consumed} = Signer.sign(signer, slot, c.wire)
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
    assert {:error, :signer_refused} = Signer.sign(c.signer, slot, c.wire)
    assert {:error, :operation_consumed} = Signer.sign(c.signer, slot, c.wire)
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
