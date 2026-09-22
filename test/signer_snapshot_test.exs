defmodule R5eRecurse.SignerSnapshotTest.Router do
  use Plug.Router
  plug(:match)
  plug(:dispatch)
  def init(agent), do: agent
  def call(conn, agent), do: super(Plug.Conn.assign(conn, :agent, agent), [])

  get "/events" do
    events =
      Agent.get_and_update(conn.assigns.agent, fn s ->
        result = if s.reads == 0, do: s.events, else: s.after_events
        {result, %{s | reads: s.reads + 1}}
      end)

    send_resp(conn, 200, Jason.encode!(%{events: events}))
  end

  get "/cas/:address" do
    bytes = Agent.get(conn.assigns.agent, &Map.get(&1.cas, address))
    if bytes, do: send_resp(conn, 200, bytes), else: send_resp(conn, 404, "missing")
  end
end

defmodule R5eRecurse.SignerSnapshotTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.{KernelClient, Signer.Snapshot}
  alias RecurseVerify.Canonical
  @origin "sha256:" <> String.duplicate("a", 64)
  @now ~U[2030-01-01 00:00:00Z]

  test "stable full history gets timestamped only after payloads and final head are checked" do
    {client, agent, events} = client()

    clock = fn ->
      assert Agent.get(agent, & &1.reads) == 2
      @now
    end

    assert {:ok, snapshot} = Snapshot.read(client, @origin, clock)
    assert snapshot.observed_at == @now
    assert snapshot.complete
    assert snapshot.head == %{seq: 1, hash: hd(events)["hash"]}
    assert [{_, %{"origin" => @origin}}] = snapshot.records
  end

  test "head growth or truncation refuses rather than silently using stale authority" do
    for mode <- [:growth, :truncated] do
      {client, _, _} = client(mode)
      assert {:error, :snapshot_unavailable} = Snapshot.read(client, @origin)
    end
  end

  test "payload tampering and wrong-origin grants refuse" do
    for mode <- [:tampered, :foreign] do
      {client, _, _} = client(mode)
      assert {:error, :snapshot_unavailable} = Snapshot.read(client, @origin)
    end
  end

  test "record lookup does not treat unsigned or missing records as verified admissions" do
    {client, _, events} = client()
    {:ok, snapshot} = Snapshot.read(client, @origin)

    assert {:error, :record_unavailable} =
             Snapshot.record(snapshot, "event:" <> hd(events)["hash"])

    assert {:error, :record_unavailable} = Snapshot.record(snapshot, "event:missing")
  end

  test "signed content Prompt re-admissions resolve within the snapshot and actor pin" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    actor = RecurseVerify.DSSE.key_id!("ed25519", public)
    spec = %{"contentRef" => %{"$ref" => "bytes:" <> Canonical.hash_bytes("body")}}

    target = %{
      "group" => "gateway.r5e.io",
      "version" => "v1alpha1",
      "kind" => "Prompt",
      "name" => nil
    }

    request = %{
      "origin" => @origin,
      "actor" => actor,
      "target" => target,
      "specAddress" => Canonical.hash(spec),
      "derivedFrom" => nil,
      "authority" => [],
      "nonce" => Base.encode64(<<0::128>>),
      "expires" => "2030-01-01T00:01:00Z"
    }

    type = "application/vnd.r5e.admission-request+json;v=1"
    bytes = Canonical.encode(request)

    signature =
      :crypto.sign(:eddsa, :none, RecurseVerify.DSSE.pae(type, bytes), [private, :ed25519])

    envelope = %{
      "payloadType" => type,
      "payload" => Base.encode64(bytes),
      "signatures" => [%{"keyid" => actor, "sig" => Base.encode64(signature)}],
      "publicKeys" => [
        %{"keyid" => actor, "algorithm" => "ed25519", "bytes" => Base.encode64(public)}
      ]
    }

    payload =
      request
      |> Map.drop(["specAddress"])
      |> Map.merge(%{
        "identity" => "signed",
        "signed" => envelope,
        "actor" => %{
          "id" => actor,
          "algorithm" => "ed25519",
          "publicKey" => Base.encode64(public)
        },
        "submittedTarget" => target,
        "target" => Map.put(target, "name", Canonical.hash(spec)),
        "spec" => spec,
        "outcome" => "admitted",
        "depth" => 0
      })

    event = %{"seq" => 1, "hash" => Canonical.hash("first"), "kind" => "admission.granted"}
    second_request = Map.put(request, "nonce", Base.encode64(<<1::128>>))
    second_bytes = Canonical.encode(second_request)

    second_signature =
      :crypto.sign(:eddsa, :none, RecurseVerify.DSSE.pae(type, second_bytes), [private, :ed25519])

    second_envelope =
      envelope
      |> Map.put("payload", Base.encode64(second_bytes))
      |> Map.put("signatures", [%{"keyid" => actor, "sig" => Base.encode64(second_signature)}])

    second_payload =
      payload |> Map.put("nonce", second_request["nonce"]) |> Map.put("signed", second_envelope)

    second_event = event |> Map.put("seq", 2) |> Map.put("hash", Canonical.hash("second"))
    # record/3 takes an already-verified Snapshot; chain integrity is tested in read/3.
    snapshot = %{origin: @origin, records: [{event, payload}, {second_event, second_payload}]}
    reference = "gateway.r5e.io/v1alpha1/Prompt/" <> Canonical.hash(spec)

    assert {:ok, %{actor: ^actor, spec: ^spec, ref: ^reference}} =
             Snapshot.record(snapshot, reference, actor)

    assert {:error, :record_unavailable} = Snapshot.record(snapshot, reference, "another")

    altered = %{
      snapshot
      | records: [{event, put_in(payload, ["spec", "contentRef", "$ref"], "bytes:wrong")}]
    }

    assert {:error, :record_unavailable} = Snapshot.record(altered, reference, actor)

    broken =
      put_in(payload, ["signed", "signatures"], [
        %{"keyid" => actor, "sig" => Base.encode64(<<0::512>>)}
      ])

    assert {:error, :record_unavailable} =
             Snapshot.record(%{snapshot | records: [{event, broken}]}, reference, actor)
  end

  @tag skip: is_nil(System.get_env("R5E_TEST_KERNEL_IMAGE"))
  test "actual isolated kernel returns a stable complete snapshot" do
    kernel = R5eRecurse.IsolatedKernel.start!()
    client = KernelClient.new(kernel.url)
    {:ok, [first | _]} = KernelClient.events_from(client, 1)
    {:ok, bytes} = KernelClient.get_cas(client, first["payload"])
    origin = Jason.decode!(bytes)["origin"]
    assert {:ok, %{complete: true, head: %{seq: count}}} = Snapshot.read(client, origin)
    assert count > 0
  end

  defp client(mode \\ :stable) do
    origin = if mode == :foreign, do: "sha256:" <> String.duplicate("b", 64), else: @origin
    payload = %{"outcome" => "admitted", "origin" => origin}

    event = %{
      "seq" => 1,
      "prev" => "sha256:" <> String.duplicate("0", 64),
      "kind" => "admission.granted",
      "payload" => Canonical.hash(payload),
      "ts" => "2030-01-01T00:00:00Z"
    }

    event = Map.put(event, "hash", Canonical.hash(event))
    events = [event]

    after_events =
      case mode do
        :growth -> events ++ [%{event | "seq" => 2}]
        :truncated -> []
        _ -> events
      end

    bytes = if mode == :tampered, do: "{}", else: Canonical.encode(payload)

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             events: events,
             after_events: after_events,
             reads: 0,
             cas: %{event["payload"] => bytes}
           }
         end},
        id: make_ref()
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {R5eRecurse.SignerSnapshotTest.Router, agent}, port: 0, ip: {127, 0, 0, 1}},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {KernelClient.new("http://127.0.0.1:#{port}"), agent, events}
  end
end
