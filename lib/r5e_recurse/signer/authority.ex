defmodule R5eRecurse.Signer.Authority do
  @moduledoc """
  Authority preflight, without signing or key custody.

  `validate(snapshot, context)` takes trusted runtime values, never wire assertions.
  Snapshot is `%{origin: origin, complete: true, head: %{seq: n, hash: hash},
  observed_at: DateTime, records: [{event, payload}]}` from a verified reader.
  Records cover the full chain from genesis through that freshly observed head.
  The reader establishes canonical source bytes, origin, admitted core issuance
  semantics and completeness against a trusted current node/checkpoint. Hashes
  and signatures alone cannot prove no omitted suffix or authorize a forged grant.
  This module rechecks chain/payload integrity and actual signatures/projections
  on all admitted authority, revocation and succession records before evaluation.

  Context contains origin, actor, task (event ref), role (Authority.Kinds atom),
  kind, refs (`%{badge: event_ref, delegation: event_ref}`), authority (exact refs),
  roots (`%{badge: issuer_root_key_id, delegation: operator_root_key_id}`), now
  (DateTime), and max_snapshot_age_seconds (positive integer, runtime policy).
  The subject must be the exact ephemeral actor; role Kind sets are exact.
  Root pins are exact identities; no implicit succession of a configured pin.

  Returns exact refs and expiry capped at five minutes and every parent term end.
  Freshness is checkpoint-relative; revocation racing subsequent admission is
  still enforced by the kernel. This does not implement generation/replay gates.
  """
  alias RecurseVerify.{Authority, Canonical, Chain, DSSE, Identity}
  alias R5eRecurse.{Authority.Kinds, Commands.Envelope}
  @credential ~w(core.r5e.io/v1/Badge core.r5e.io/v1/Endorsement)
  @relevant @credential ++ ~w(core.r5e.io/v1/Revocation core.r5e.io/v1/Succession)

  def validate(snapshot, ctx) do
    with :ok <- snapshot?(snapshot, ctx),
         {:ok, kinds} <- Kinds.for_role(ctx.role),
         true <- ctx.kind in kinds,
         true <- DSSE.key_id?(ctx.actor) and event_ref?(ctx.task),
         true <- exact_refs?(ctx),
         relevant =
           Enum.filter(snapshot.records, fn {_, p} ->
             p["outcome"] == "admitted" and kind(p) in @relevant
           end),
         true <- Enum.all?(relevant, &signed?/1),
         index = Authority.build(snapshot.records),
         records = Map.new(relevant, fn {e, p} -> {"event:" <> e["hash"], p} end),
         :ok <- credential(records[ctx.refs.badge], "Badge", ctx, kinds),
         :ok <- credential(records[ctx.refs.delegation], "Endorsement", ctx, kinds),
         position = snapshot.head.seq + 1,
         now = DateTime.to_iso8601(ctx.now),
         true <- effective?(index, ctx.refs.badge, ctx.roots.badge, position, now),
         true <- effective?(index, ctx.refs.delegation, ctx.roots.delegation, position, now),
         links =
           Authority.links(index, ctx.refs.badge) ++ Authority.links(index, ctx.refs.delegation),
         expires =
           Enum.reduce(links, DateTime.add(ctx.now, 300, :second), fn link, limit ->
             {:ok, ending, _} = DateTime.from_iso8601(link["notAfter"])
             if DateTime.compare(ending, limit) == :lt, do: ending, else: limit
           end),
         :gt <- DateTime.compare(expires, ctx.now) do
      {:ok,
       %{authority: ctx.authority, expires: DateTime.to_iso8601(expires), head: snapshot.head}}
    else
      _ -> {:error, :authority_unavailable}
    end
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    _, _ -> {:error, :authority_unavailable}
  end

  defp snapshot?(s, ctx) do
    with true <- s.complete == true and s.origin == ctx.origin,
         true <- is_binary(ctx.origin) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, ctx.origin),
         true <- is_integer(ctx.max_snapshot_age_seconds) and ctx.max_snapshot_age_seconds > 0,
         age = DateTime.diff(ctx.now, s.observed_at, :microsecond),
         true <- age >= 0 and age <= ctx.max_snapshot_age_seconds * 1_000_000,
         true <- is_list(s.records) and s.records != [],
         events = Enum.map(s.records, &elem(&1, 0)),
         {:ok, count} <- Chain.verify_events(events),
         true <- s.head.seq == count and s.head.hash == List.last(events)["hash"],
         true <-
           Enum.all?(s.records, fn {e, p} ->
             Canonical.hash(p) == e["payload"] and
               (p["outcome"] != "admitted" or
                  (e["kind"] == "admission.granted" and p["origin"] == ctx.origin))
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp signed?({_event, payload} = record) do
    with "signed" <- payload["identity"],
         {:ok, _} <- Envelope.verify_signed(payload["signed"]),
         {_, [], %{signed: 1, admissions: 1, legacy: 0}} <- Identity.check_signatures([record]) do
      credential_signature_shape?(payload)
    else
      _ -> false
    end
  end

  defp credential_signature_shape?(%{
         "target" => %{"kind" => type},
         "spec" => spec,
         "signed" => signed
       })
       when type in ["Badge", "Endorsement"] do
    with %{"algorithm" => "ed25519", "bytes" => encoded} <- spec["subjectKey"],
         {:ok, public} <- DSSE.decode64(encoded),
         true <- DSSE.key_id!("ed25519", public) == spec["subject"] do
      case {type, signed["signatures"]} do
        {"Badge", [_, %{"keyid" => subject}]} -> subject == spec["subject"]
        {"Endorsement", [_]} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp credential_signature_shape?(_), do: true

  defp credential(p, type, ctx, kinds) when is_map(p) do
    spec = p["spec"]

    if kind(p) == "core.r5e.io/v1/" <> type and spec["subject"] == ctx.actor and
         spec["role"] == Atom.to_string(ctx.role) and spec["mayIssue"] == false and
         spec["scope"] == %{"task" => ctx.task} and Enum.sort(spec["kinds"]) == kinds and
         (type != "Badge" or
            spec["subjectKind"] == if(ctx.role == :runtime_action, do: "service", else: "agent")),
       do: :ok,
       else: :error
  end

  defp credential(_, _, _, _), do: :error

  defp exact_refs?(ctx) do
    refs = [ctx.refs.badge, ctx.refs.delegation]

    Enum.all?(refs, &event_ref?/1) and length(Enum.uniq(refs)) == 2 and
      is_list(ctx.authority) and Enum.sort(ctx.authority) == Enum.sort(refs)
  end

  defp effective?(index, ref, root, position, now) do
    DSSE.key_id?(root) and
      case Authority.effective(index, ref, position, now) do
        %{ok: true, root: ^root} -> true
        _ -> false
      end
  end

  defp kind(p), do: Enum.map_join(~w(group version kind), "/", &p["target"][&1])
  defp event_ref?(r), do: is_binary(r) and Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, r)
end
