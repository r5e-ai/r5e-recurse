defmodule R5eRecurse.NonceScanTest do
  use ExUnit.Case, async: true
  alias RecurseVerify.{Canonical, DSSE}
  alias R5eRecurse.NonceJournal.{Entry, Scan}

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    actor = DSSE.key_id!("ed25519", public)
    origin = "sha256:" <> String.duplicate("a", 64)

    candidate = %{
      "target" => %{"group" => "test", "version" => "v1", "kind" => "Test", "name" => nil},
      "spec" => %{"value" => "exact"}
    }

    request = %{
      "origin" => origin,
      "actor" => actor,
      "target" => candidate["target"],
      "specAddress" => Canonical.hash(candidate["spec"]),
      "derivedFrom" => nil,
      "authority" => [],
      "nonce" => Base.encode64(<<0::128>>),
      "expires" => "2000-01-01T00:00:00Z"
    }

    ctx = %{public: public, private: private, actor: actor}

    entry = %{
      "operationId" => "op",
      "origin" => origin,
      "generation" => %{"bootId" => "boot", "runId" => "run"},
      "candidate" => candidate,
      "candidateDigest" => Canonical.hash(candidate),
      "status" => "prepared",
      "request" => request,
      "envelope" => sign(ctx, request)
    }

    assert Entry.valid?(entry, origin)
    Map.put(ctx, :entry, entry)
  end

  test "journal preserves every core timestamp spelling including nanoseconds", ctx do
    for expires <- [
          "2000-01-01t00:00:00z",
          "2000-01-01T00:00:00-00:00",
          "2000-01-01T00:00:00.000000001Z"
        ] do
      request = Map.put(ctx.entry["request"], "expires", expires)
      entry = Map.merge(ctx.entry, %{"request" => request, "envelope" => sign(ctx, request)})
      assert Entry.valid?(entry, entry["origin"])

      assert {:denied, %{"seq" => 1}, _} =
               Scan.resolve(
                 [record(ctx, request, 1, "authenticate: expired: old timestamp")],
                 entry
               )
    end
  end

  test "actor mismatch does not consume the nonce; later exact request does", ctx do
    wrong = Map.put(ctx.entry["request"], "actor", "different-claimed-actor")
    early = record(ctx, wrong, 1, "authenticate: actor mismatch: claimed actor differs")
    later = record(ctx, ctx.entry["request"], 2, nil)
    assert {:ok, %{"seq" => 2}, _} = Scan.resolve([early, later], ctx.entry)
  end

  test "expired authentication denial consumes the nonce and is recoverable", ctx do
    denied = record(ctx, ctx.entry["request"], 1, "authenticate: expired: old timestamp")
    assert {:denied, %{"seq" => 1}, _} = Scan.resolve([denied], ctx.entry)
  end

  test "replay denial cannot stand in for missing original outcome", ctx do
    replay =
      record(ctx, ctx.entry["request"], 2, "authenticate: nonce replayed: already recorded")

    assert {:outcome_unknown, %{reason: :not_observed}} = Scan.resolve([replay], ctx.entry)
  end

  test "unknown denial stage stops recovery instead of silently skipping it", ctx do
    unknown = record(ctx, ctx.entry["request"], 1, "futureStage: unknown semantics")
    later = record(ctx, ctx.entry["request"], 2, nil)

    assert {:outcome_unknown, %{reason: :malformed_history}} =
             Scan.resolve([unknown, later], ctx.entry)
  end

  test "candidate substitution cannot change the signed bytes on restart", ctx do
    changed = put_in(ctx.entry, ["candidate", "spec", "value"], "substituted")
    changed = Map.put(changed, "candidateDigest", Canonical.hash(changed["candidate"]))
    refute Entry.valid?(changed, changed["origin"])
    assert {:outcome_unknown, %{reason: :invalid_journal_entry}} = Scan.resolve([], changed)
  end

  defp record(ctx, request, seq, reason) do
    payload = %{
      "actor" => %{"id" => ctx.actor},
      "nonce" => request["nonce"],
      "origin" => request["origin"],
      "submittedTarget" => request["target"],
      "signed" => sign(ctx, request),
      "spec" => ctx.entry["candidate"]["spec"],
      "outcome" => if(reason, do: "denied", else: "admitted")
    }

    payload = if reason, do: Map.put(payload, "reason", reason), else: payload

    %{
      event: %{
        "kind" => if(reason, do: "admission.denied", else: "admission.granted"),
        "seq" => seq,
        "hash" => Canonical.hash(payload)
      },
      payload: payload
    }
  end

  defp sign(ctx, request) do
    type = "application/vnd.r5e.admission-request+json;v=1"
    payload = Canonical.encode(request)
    signature = :crypto.sign(:eddsa, :none, DSSE.pae(type, payload), [ctx.private, :ed25519])

    %{
      "payloadType" => type,
      "payload" => Base.encode64(payload),
      "signatures" => [%{"keyid" => ctx.actor, "sig" => Base.encode64(signature)}],
      "publicKeys" => [
        %{"keyid" => ctx.actor, "algorithm" => "ed25519", "bytes" => Base.encode64(ctx.public)}
      ]
    }
  end
end
