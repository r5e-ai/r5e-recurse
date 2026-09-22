defmodule R5eRecurse.Signer.AuthorityTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Signer.Authority
  alias R5eRecurse.Authority.Kinds
  alias RecurseVerify.{Canonical, Chain, DSSE}
  @now ~U[2030-01-01 12:00:00Z]
  @kind "gateway.r5e.io/v1alpha1/LlmCall"
  @origin "sha256:" <> String.duplicate("a", 64)
  @task "event:sha256:" <> String.duplicate("b", 64)

  test "actual issuer and subject signatures, parent chain and exact refs yield capped expiry" do
    {snapshot, ctx} = fixture()
    assert {:ok, result} = Authority.validate(snapshot, ctx)
    assert result.authority == ctx.authority
    assert result.head == snapshot.head
    assert result.expires == "2030-01-01T12:05:00Z"
    {snapshot, ctx} = fixture(delegation_changes: %{"notAfter" => "2030-01-01T12:02:00Z"})
    assert {:ok, %{expires: "2030-01-01T12:02:00Z"}} = Authority.validate(snapshot, ctx)
  end

  test "wrong subject, task, role, widened or missing kinds refuse" do
    for options <- [
          [wrong_subject: true],
          [badge_changes: %{"scope" => %{"task" => "other"}}],
          [delegation_changes: %{"role" => "reviewer"}],
          [badge_changes: %{"kinds" => ["*"]}],
          [delegation_changes: %{"kinds" => []}],
          [badge_changes: %{"mayIssue" => true}],
          [badge_changes: %{"subjectKind" => "service"}]
        ] do
      {snapshot, ctx} = fixture(options)
      assert {:error, :authority_unavailable} = Authority.validate(snapshot, ctx)
    end
  end

  test "wrong pinned root or disallowed requested Kind refuses" do
    {snapshot, ctx} = fixture()

    for context <- [
          put_in(ctx.roots.badge, key().id),
          put_in(ctx.roots.delegation, key().id),
          %{ctx | kind: "recurse.r5e.io/v1alpha1/Review"}
        ] do
      assert {:error, :authority_unavailable} = Authority.validate(snapshot, context)
    end
  end

  test "missing, duplicate or substituted authority refuses" do
    {snapshot, ctx} = fixture()

    for refs <- [
          [],
          [ctx.refs.badge],
          [ctx.refs.badge, ctx.refs.badge],
          ctx.authority ++ [ctx.refs.badge],
          [ctx.refs.badge, @task]
        ] do
      assert {:error, _} = Authority.validate(snapshot, %{ctx | authority: refs})
    end

    assert {:ok, _} =
             Authority.validate(snapshot, %{ctx | authority: Enum.reverse(ctx.authority)})
  end

  test "expired, future, revoked parent and parent issuance constraints refuse" do
    for options <- [
          [delegation_changes: %{"notAfter" => "2030-01-01T11:59:59Z"}],
          [badge_changes: %{"notBefore" => "2030-01-01T12:00:01Z"}],
          [revoke_parent: true],
          [parent_changes: %{"mayIssue" => false}],
          [parent_changes: %{"kinds" => []}],
          [parent_changes: %{"notAfter" => "2030-01-01T11:59:59Z"}]
        ] do
      {snapshot, ctx} = fixture(options)
      assert {:error, _} = Authority.validate(snapshot, ctx)
    end
  end

  test "cryptographically corrupt issuer or subject signature refuses even with intact hashes" do
    for index <- [0, 1] do
      {snapshot, ctx} = fixture()

      changed =
        alter(snapshot, 1, fn p ->
          update_in(p, ["signed", "signatures"], fn signatures ->
            List.update_at(signatures, index, &Map.put(&1, "sig", Base.encode64(<<0::512>>)))
          end)
        end)

      assert {:error, _} = Authority.validate(changed, rebind(ctx, changed))
    end
  end

  test "Badge missing countersignature, wrong second signer and unsigned authority refuse" do
    {snapshot, ctx} = fixture()

    for transform <- [
          fn p -> update_in(p, ["signed", "signatures"], &Enum.take(&1, 1)) end,
          fn p ->
            update_in(p, ["signed", "signatures"], fn [issuer, _] -> [issuer, issuer] end)
          end,
          fn p -> Map.delete(p, "identity") end,
          fn p -> put_in(p, ["spec", "subjectKey", "bytes"], Base.encode64(key().public)) end
        ] do
      changed = alter(snapshot, 1, transform)
      assert {:error, _} = Authority.validate(changed, rebind(ctx, changed))
    end
  end

  test "signature over different recorded scope or origin cannot authorize altered credential" do
    {snapshot, ctx} = fixture()

    assert {:error, _} =
             Authority.validate(
               alter(snapshot, 1, fn p -> put_in(p, ["spec", "scope"], %{"task" => "forged"}) end),
               ctx
             )

    assert {:error, _} =
             Authority.validate(
               alter(snapshot, 1, fn p ->
                 Map.put(p, "origin", "sha256:" <> String.duplicate("c", 64))
               end),
               ctx
             )
  end

  test "incomplete, stale, future, truncated, changed payload and foreign snapshots refuse" do
    {snapshot, ctx} = fixture()
    [{event, payload} | tail] = snapshot.records

    for invalid <- [
          %{snapshot | complete: false},
          %{snapshot | observed_at: DateTime.add(@now, -6, :second)},
          %{snapshot | observed_at: DateTime.add(@now, 1, :second)},
          %{snapshot | records: Enum.drop(snapshot.records, 1)},
          %{snapshot | records: [{event, Map.put(payload, "extra", true)} | tail]},
          %{snapshot | origin: "foreign"},
          %{snapshot | head: %{snapshot.head | seq: 99}}
        ] do
      assert {:error, :authority_unavailable} = Authority.validate(invalid, ctx)
    end

    assert {:error, _} = Authority.validate(nil, ctx)
  end

  defp fixture(opts \\ []) do
    deployment = key()
    root = key()
    operator = key()
    session = key()
    subject = if opts[:wrong_subject], do: key(), else: session
    {:ok, kinds} = Kinds.for_role(:producer)

    base = fn subject ->
      %{
        "subject" => subject.id,
        "subjectKey" => %{"algorithm" => "ed25519", "bytes" => Base.encode64(subject.public)},
        "role" => "producer",
        "scope" => %{"task" => @task},
        "kinds" => kinds,
        "mayIssue" => false,
        "notBefore" => "2030-01-01T11:00:00Z",
        "notAfter" => "2030-01-01T13:00:00Z"
      }
    end

    parent =
      base.(operator)
      |> Map.merge(%{"mayIssue" => true, "subjectKind" => "service"})
      |> Map.merge(opts[:parent_changes] || %{})

    records = append([], "Badge", parent, root, [root, operator], [])
    parent_ref = event_ref(List.last(records))

    badge =
      base.(subject) |> Map.put("subjectKind", "agent") |> Map.merge(opts[:badge_changes] || %{})

    records = append(records, "Badge", badge, deployment, [deployment, subject], [])
    badge_ref = event_ref(List.last(records))

    delegation =
      base.(subject)
      |> Map.put("parent", %{"$ref" => parent_ref})
      |> Map.merge(opts[:delegation_changes] || %{})

    records = append(records, "Endorsement", delegation, operator, [operator], [parent_ref])
    delegation_ref = event_ref(List.last(records))

    records =
      if opts[:revoke_parent],
        do:
          append(records, "Revocation", %{"revokes" => %{"$ref" => parent_ref}}, root, [root], []),
        else: records

    snapshot = snapshot(records)

    ctx = %{
      origin: @origin,
      actor: session.id,
      task: @task,
      role: :producer,
      kind: @kind,
      refs: %{badge: badge_ref, delegation: delegation_ref},
      authority: [badge_ref, delegation_ref],
      roots: %{badge: deployment.id, delegation: root.id},
      now: @now,
      max_snapshot_age_seconds: 5
    }

    {snapshot, ctx}
  end

  defp append(records, type, spec, issuer, signers, authority) do
    target = %{"group" => "core.r5e.io", "version" => "v1", "kind" => type, "name" => nil}

    request = %{
      "origin" => @origin,
      "actor" => issuer.id,
      "target" => target,
      "specAddress" => Canonical.hash(spec),
      "derivedFrom" => nil,
      "authority" => authority,
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "expires" => "2030-01-01T12:01:00Z"
    }

    type_name = "application/vnd.r5e.admission-request+json;v=1"
    bytes = Canonical.encode(request)

    signed = %{
      "payloadType" => type_name,
      "payload" => Base.encode64(bytes),
      "signatures" =>
        Enum.map(signers, fn s ->
          %{
            "keyid" => s.id,
            "sig" =>
              Base.encode64(
                :crypto.sign(:eddsa, :none, DSSE.pae(type_name, bytes), [s.private, :ed25519])
              )
          }
        end),
      "publicKeys" =>
        Enum.map(signers, fn s ->
          %{"keyid" => s.id, "algorithm" => "ed25519", "bytes" => Base.encode64(s.public)}
        end)
    }

    payload =
      Map.drop(request, ["specAddress"])
      |> Map.merge(%{
        "identity" => "signed",
        "signed" => signed,
        "actor" => %{
          "id" => issuer.id,
          "algorithm" => "ed25519",
          "publicKey" => Base.encode64(issuer.public)
        },
        "submittedTarget" => target,
        "spec" => spec,
        "outcome" => "admitted",
        "depth" => if(authority == [], do: 0, else: 1)
      })

    rechain(records ++ [{%{}, payload}])
  end

  defp rechain(records) do
    {records, _} =
      Enum.map_reduce(Enum.with_index(records, 1), Chain.genesis(), fn {{_, p}, seq}, prev ->
        e = %{
          "seq" => seq,
          "prev" => prev,
          "kind" => "admission.granted",
          "ts" => "2030-01-01T11:59:50Z",
          "payload" => Canonical.hash(p)
        }

        e = Map.put(e, "hash", Canonical.hash(e))
        {{e, p}, e["hash"]}
      end)

    records
  end

  defp snapshot(records) do
    {last, _} = List.last(records)

    %{
      origin: @origin,
      complete: true,
      head: %{seq: last["seq"], hash: last["hash"]},
      observed_at: @now,
      records: records
    }
  end

  # Preserve reference identity after adversarially rebuilding an internally
  # consistent chain, so signature refusals cannot pass due to a missing ref.
  defp rebind(ctx, s) do
    badge = event_ref(Enum.at(s.records, 1))
    delegation = event_ref(Enum.at(s.records, 2))
    %{ctx | refs: %{badge: badge, delegation: delegation}, authority: [badge, delegation]}
  end

  defp alter(s, index, fun),
    do: snapshot(rechain(List.update_at(s.records, index, fn {e, p} -> {e, fun.(p)} end)))

  defp event_ref({e, _}), do: "event:" <> e["hash"]

  defp key do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private, id: DSSE.key_id!("ed25519", public)}
  end
end
