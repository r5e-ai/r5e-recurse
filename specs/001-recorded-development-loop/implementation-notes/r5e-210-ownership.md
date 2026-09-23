# R5E210 Commands writer ownership

Commands previously held an origin lock in a helper while its Elixir callback performed the write. If that helper died while history refresh was paused, a replacement could acquire ownership before the old callback submitted. This repair moves pending publication, the actual HTTP request, and finalization into the same Python process that holds the existing cooperative `/var/tmp/r5e-recurse-writer-<origin>` flock.

## API and lifetime

A store provides `client(store)`, returning its `KernelClient`, and pure `prepare_submit(store, spec, envelope)`, returning `{:ok, %{spec: spec, envelope: envelope, body: bytes, body_digest: digest}}`. The body contains exactly the supplied spec and envelope with `name: null`; its digest is SHA-256. Commands rejects unsupported preparation rather than calling an arbitrary store submission callback. The broker pins the configured client URL and timeout at initialization; the helper supplies POST and the Command route, preserving the configured URL path prefix.

Commands retains one linked broker PID and lifetime token. The broker owns the helper Port, monitors Commands and the submitting callback, validates preparation, and uses the shared `KernelClient.decode_write/1` receipt decoder. Calls never reconnect to a replacement broker or retry a write. The helper has one dispatch/finalize exchange at a time and requires its current attempt token before finalization. Publication and HTTP use an absolute helper-local deadline, including blocked DNS or filesystem work; finalize has a separate deadline. Loss poisons the broker and closes its control channel.

The guarantee is dispatch exclusion within one cooperative host namespace. The helper does not release the flock while its dispatch code can still execute. Closing the Port is not evidence that the helper has exited, and an already-authorized request can finish during teardown. Replacement acquisition remains governed by the OS lock. This does not establish global network ordering or retract bytes already sent.

## Durable outcomes

Normal markers retain the existing semantic filename and strict `sha256:` digest format. They are published through a private temporary file, file fsync, exclusive hard link, and directory fsync. Malformed or unreadable existing markers preserve uncertainty; only a valid differing digest supports a pending conflict. Accepted markers remain retained.

Explicit replay dispatches allocate distinct local attempt IDs and immutable `replay-v1/<attempt-id>.json` sidecars before sending. They never overwrite the semantic marker. Sidecars include origin, caller, scoped command ID, payload and envelope digests, nonce, and transport-body digest; the local attempt ID is not added to the signed request. A confirmed signed denial or unrecorded refusal removes only the current exchange's record after acknowledged finalization. Unknown results and unexpected replay admission retain the sidecar. Repeated explicit submits can create new replay attempts; startup, lookup, and history refresh do not replay automatically.

Unresolved sidecars survive restart. Semantic lookup cannot uniquely resolve them, even when history contains a byte-identical replay denial. A diagnostic API, reconciliation, and garbage collection remain deferred to R5E226/R5E227; this change provides the durable records, not that recovery workflow.

A known receipt followed by missing cleanup/finalization acknowledgment returns `{:outcome_unknown, details}` with the known outcome attached and cleanup marked unacknowledged. A receipt that is itself uncertain is not labeled a known outcome. Helper or broker loss also returns unknown; replay results preserve the allocated attempt ID even if the pinned broker dies. No outcome authorizes an automatic retry.

## Integration and operations

This change does not complete Boot integration, introduce a runtime supervisor, or share this owner with NonceJournal or signing custody. The independent broker can serve a future Boot callback while Commands waits, but the complete Boot/callback death matrix is not established here. Operations remain unimplemented stubs; no new authority is introduced.

Upgrade requires stopping and waiting for old Commands processes and all outstanding Boot callbacks to finish or terminate before starting new owners. Killing only old helpers is insufficient. The namespace gains a version sentinel and the `replay-v1` directory. There is no supported rollback to a legacy binary against a namespace containing unresolved replay sidecars; legacy code ignores the new sentinel. Preserve records rather than deleting them to permit downgrade.

## Validation and limits

The final Docker `MIX_ENV=test` run, including the disposable local HTTP integration fixture, completed with 67 tests, zero failures, 13 skipped, and three excluded. The ExUnit helper wrapper runs ten Python persistence/protocol cases. Production compilation passed with warnings treated as errors.

Coverage includes real helper/HTTP admission, normal and replay fencing after helper death during paused history refresh, distinct retained replay IDs, broker death preserving a replay ID, finalization acknowledgment loss with known acceptance, malformed markers, exclusive publication, injected file/directory fsync failures, wrong or partial finalize frames, absent finalize, replacement exclusion while a helper retains its lock during paused HTTP, and an absolute deadline against slow-progress response bytes.

This is not a complete fault-injection matrix: blocked DNS/connect/TLS and callback/Boot death at every persistence boundary were not explicitly exercised. No live chain, credentials, deployment, or rollback was used for validation. Receipts remain kernel claims, and contract HTTP fixtures do not independently prove canonical kernel behavior.
