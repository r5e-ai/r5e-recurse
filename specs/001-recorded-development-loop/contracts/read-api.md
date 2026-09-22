# Read API v1

Proposed JSON-over-HTTP contract independent of Elixir/Phoenix internals. Initial listener is loopback with operator-issued read credentials. Public exposure and publication require separate deployment/disclosure configuration. The read credential is not session signing authority and does not grant mutation.

## Endpoints

| Method/path | Result |
|---|---|
| `GET /v1/tasks/{id}` | Task, Node, attempt links, derived lifecycle, session/artifact/review/decision/reflection refs. |
| `GET /v1/sessions/{id}` | Session binding, signer/Badge/custody, provider/harness assertions, supplied context, capture scope, outcomes. |
| `GET /v1/tasks/{id}/events` | Ordered related canonical event references plus derived relation labels. |
| `GET /v1/artifacts/{id}` | Artifact metadata, digest, lineage, source admission, payload availability. |
| `GET /v1/artifacts/{id}/content` | Authorized exact bytes with recorded media type and digest; never a modified original. |
| `GET /v1/revisions?repo_id=...&revision=...&object_format=...` | Recorded associations with tasks/artifacts/pushes; no match does not imply no work happened. |
| `GET /v1/commands/{id}` | Caller-authorized lookup of semantic command identity and its known result. |
| `GET /v1/evidence?ref=...&snapshot_id=...` | Authorized canonical event/resource-at-admission/bytes metadata dereference; includes decoded available payload and links for context, review, decision, reflection and lesson records. |
| `GET /v1/snapshots/{id}` | Covered origin/sequence/checkpoint, index version, capture/disclosure limits and available offline-bundle metadata. |

Opaque IDs are URL-encoded; canonical resource names may contain slashes and must not be naively split into IDs. Response links carry exact canonical refs in addition to reader-friendly IDs. Endpoint fields are JSON primitives, not serialized language structs.

## Response envelope

Every metadata response includes `api_version: "v1"`, `data`, `coverage` and `links`. `coverage` contains:

- `origin`: canonical chain identity.
- `snapshot_id`: fixed snapshot selected at first read or supplied by the reader.
- `through_seq`, `checkpoint_ref`, `indexed_through_seq`, `index_version`.
- `capture_profile`: cooperative local scope and explicitly excluded effects.
- `disclosure`: private/full selected record or an explicit subset; withheld/missing counts and limitations.

Each derived object includes its `source_event_refs`. Snapshot metadata identifies a checkpoint whose covered sequence contains those events. If the current index lags, choose and report the older fully indexed checkpoint; never report the live head as fully indexed. No coherent checkpoint available returns a retryable coverage error, not invented evidence.

## Pagination

Collection queries accept `limit` (default 50, maximum 200), `cursor`, and optional `snapshot_id` for the first page. Sort related events by canonical sequence, using event ref as a deterministic tie-breaker for derived relations. An opaque cursor binds origin, snapshot, endpoint/query/filter, last ordering key and index version. Reject a changed filter or incompatible cursor with `400 invalid_cursor`.

`next_cursor` is null when exhausted. Read limit+1 or an equivalent exact exhaustion check; exactly limit items alone does not prove another page exists. New chain events do not enter an existing snapshot. Preserve snapshot metadata for at least 24 hours initially; after expiry return `410 snapshot_expired`, requiring an explicit new snapshot. An index rebuild may serve the same snapshot only if it reproduces its version/coverage; otherwise report expiration, never silently continue on a changed snapshot.

## Missing content and errors

Metadata exposes `payload_status` as `available`, `withheld`, `expired`, `missing` or `capture_incomplete`. Authorized metadata does not imply payload access. Content access uses `401/403` for authorization, `404` unknown object, `410` recorded expiry and `503` temporary source/coverage failure. Missing bytes are not synthesized from a summary. Privacy-sensitive IDs are not revealed to unauthorized readers; authorization applies before descriptive errors.

Errors use `{"api_version":"v1","error":{"code":"...","message":"...","retryable":false}}`. No raw token, private key, filesystem secret path or provider auth body appears in an error. Credentials authorize reads but are not embedded in links/cursors.

## Coherent export

The facade exposes metadata for a prepared canonical bundle, not unrestricted filesystem export paths. Initial preparation quiesces **all writers to the selected development chain**, captures/export-checks one checkpoint, verifies unchanged head across export, and runs the reference verifier. If complete writer quiescence cannot be established or head changes, discard the candidate and refuse to label it coherent. A later fixed snapshot exporter may remove this requirement.

The acceptance run uses explicit reader pins and `house` posture for Badge-containing local evidence; other readers choose their own posture and pins. Preserve verifier output and every not-checked limitation. A local bundle is not an independently anchored public witness. Disclosure subsets identify missing material and verification consequences; do not strip private bytes from an original and call it the same full export.

## Consumer acceptance

An inspector consumes the facade. A second independent Python 3 standard-library reader reconstructs task/review/lesson lineage directly from the exported canonical bundle, with **no facade calls**, then diffs its edges and source event refs against the facade at the same checkpoint. Include a deliberately omitted/mislabeled index edge and require a detected mismatch. A separate HTTP contract test still demonstrates non-Elixir facade consumption. Test page boundaries, tied projection sort keys, index lag/rebuild, cursor/query mismatch, snapshot expiry, unavailable payloads and credential denial. Neither client reads process memory or runtime database tables. A viewer is optional and cannot replace these checks.

Evidence dereference is snapshot-bound: a ref after the covered checkpoint returns `409 outside_snapshot`; unknown refs return 404 only after authorization. Event results include canonical envelope, exact payload-byte digest/reference and the decoded payload when available. Decoded JSON is a convenience; verification uses exact bytes. Bytes metadata points to an authorized content link. Resource references resolve the captured admission version at that snapshot, never silently to the live replacement. This route makes the entire lineage traversable without knowledge of private kernel endpoints.

## Read credential and caller mapping

Server-side read-credential records map an opaque credential ID to one authenticated principal key and an explicit set of permitted command-owner keys/scopes. `GET /v1/commands/{id}` resolves `(ownerKey, commandId)` using that mapping, not a caller-supplied identity header; an optional owner selector must belong to the allowed set. Without a selector, use the credential's own principal key. Cross-owner inspection requires explicit operator-issued read scope; decision Endorsement alone does not confer read access. Test identical command IDs owned by different keys, revoked/expired read credentials and forged owner selectors. Credentials are never emitted in evidence/links; only their non-secret principal/scope reference is recorded where needed.

Session and task reads expose policy-enforced custody/profile from their source records and label orphan LlmCall-without-ManagedRequest as `not_dispatched` within the managed profile at the snapshot. A reader cannot infer all-world nonexecution from that label.

Both clients use fixtures and acceptance based on the same exported canonical bytes. Independent reading and hash verification must not be presented as full independent signature verification unless that verification is implemented and tested; preserve the separate reference-verifier result and its limitations.
