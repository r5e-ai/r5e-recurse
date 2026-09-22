# Execution and command contract

Proposed runtime interface, version 1. No command below is shipped by this planning change.

## Command envelope

A control request carries `command_id`, `operation`, `origin`, `target`, `expected_state_ref` where applicable, and a canonical operation payload. The authenticated caller's key scopes `command_id`. The runtime records the admitted command and returns its canonical event ref, target IDs and one of `accepted`, `denied`, `existing`, `conflict` or `outcome_unknown`.

Operations initially: `submit_task`, `start_session`, `cancel_session`, `record_decision`, `request_push`, `recover_attempt`, `select_lesson`. No generic “retry whatever failed” command exists. Control decisions use an operator-role key or a reviewer session with an effective operator-issued Endorsement scoped to decision Kinds and task/target/term. The runtime is a service custodian, not the orchestrator or an implicit decision authority; model text is not a recorded delegation.

Same command ID and identical digest returns the existing semantic operation and current observed result. Same ID and different digest refuses without dispatch. A protocol nonce replay is still a recorded denial under core rules; it is not semantic command deduplication. Admission and dispatch are separate transitions. If acknowledgment is lost, query by command ID; do not automatically create a fresh command.

## Adapter interface

- `capabilities()` declares harness version, supported auth/transport modes, context/control inputs, exposed output events, cancellation/descendant guarantees, tool restrictions and evidence limits.
- `prepare(session)` validates executable, exact context refs, selected model/auth mode, separate workspace, gateway route and configured budgets. Returns a prepared handle without launching.
- `start(prepared)` runs only after launch admission and SessionBinding. Returns a monitored handle including session ID and execution generation; it never grants itself authority.
- `observe(handle)` emits ordered raw chunks and parsed events when supported, with stream/sequence and source labels. OS exit is separate from model completion.
- `cancel(handle, reason)` requests graceful stop, escalates after the configured interval, and reports observed termination or uncertainty.
- `reconcile(binding)` reports live/stopped/unknown ownership and recoverable spool state without executing the task.

Adapters own invocation and parsing; they do not own workflow policy, independent review, acceptance or lesson selection. They receive a session-scoped local routing credential, not the session signing key. Provider authentication remains with the supported client path. Only non-secret effective settings enter evidence.

## Process contract

Use temporary workers under a DynamicSupervisor and explicit owner monitoring. A supported local process launcher must create an identifiable process group, retain ownership/generation information and support group termination. `Port.close` alone is not a cancellation implementation. On macOS, use a tested small POSIX launcher/helper if the chosen Port wrapper cannot establish/process group ownership itself; this must be validated before claiming descendant cancellation. No shell command concatenation for tasks or Git arguments.

Test a child and grandchild that emit a heartbeat. Cancellation must observe exit and stopped output. A deliberately detached descendant may exceed the cooperative profile; surface the limitation and refuse tasks requiring stronger containment. Recovered PID alone is not sufficient identity because PIDs can be reused. If ownership cannot be established, mark unknown and require operator reconciliation. No automatic restart of an execution worker after a supervisor restart.

Maintain independent idle and hard timers; retain actual timer handles, tag messages with execution generation, cancel handles correctly and ignore stale generations. Continuous output cannot extend the hard deadline. A caller's timeout is not proof that its subprocess ended.

## Harness isolation and effective configuration

Every producer and reviewer launches with an isolated HOME/config directory and no inherited conversation memory, global instruction files, hooks, plugins or integrations. Implementation must use supported harness isolation/config controls and prove their effect for the pinned CLI. If mandatory machine configuration cannot be disabled, explicitly capture its non-secret digest and effects; incompatible hidden input blocks fresh-context acceptance.

Do not expose the normal home directory merely to reuse subscription authentication. Use the client-supported credential mechanism with minimal auth-only provisioning; never copy the whole home/config tree or place credentials in the ContextManifest. Compatibility between isolated configuration and subscription auth is an A1 acceptance check, not an assumed flag.

In read-only review views, ignore project `CLAUDE.md`, `AGENTS.md`, `.claude/` and `.codex/` instructions, hooks and configuration. Prefer a separate sanitized materialization or proven harness suppression; retain the immutable original artifact and record exclusions, without editing its evidence bytes. Producers also suppress auto-loading and receive selected project instructions through the explicit manifest. Record the digest and origin of **every effective non-secret harness config/instruction file**, CLI overrides and sanitized-view mapping. Secret auth state is inventoried by credential reference, never hashed into public evidence or copied as config content.

Fixture: put a marker-writing hook and contaminating instructions in the reviewed checkout and ambient home. Run the real pinned reviewer harness with isolated configuration; assert no marker and no inherited instruction in effective input. Unsupported suppression refuses launch. This tests configuration execution, not whether a model happens to resist hostile prose.

## Context and output

Capture exact rendered input and complete source/omission manifest before launch. Read from an explicit repository root/revision, never process CWD or fixed home paths. The first ManagedRequest must contain the rendered input verbatim as the specified decoded provider input string; record field path/digest and refuse a mismatch. Runtime-control records use the service principal, while the manifest/binding describe the session subject: policy requires `custody: runtime-held`, `profile: cooperative-local` and the configured coverage labels on ContextManifest/SessionBinding; read views derive these labels from admitted records. Required missing/unsupported parts fail preparation. Optional omissions state source and reason. Reviewer context is freshly assembled from immutable target, criteria, policy and explicitly selected overlap; default producer private memory is absent.

Spool raw stdout/stderr separately with bounded chunks and sequence. Preserve original bytes; parsed events are derived and cite their chunk coverage. Incomplete JSON/UTF-8 frames buffer within bounds. Read final result files before deleting temporary files. Nonzero exit, CLI-reported failure and truncation cannot be normalized to success. An agent saying “done” is not an OS-success or admitted-artifact signal.

Admit captured chunks and a manifest referencing all chunks in order. Spool failure or exhausted limits stops further managed execution and records capture incompleteness if admission remains available. If admission is unavailable, preserve local diagnostic/spool state without presenting it as a canonical event. Recovery admits later observations with honest timing.

## Stateless authority, disposable routing state

Authority and the record live on the chain and are reconstructed from it. Disposable caches/indexes/spools do not authorize work. Only the live CLI process ↔ local route + run credential + boot/run generation binding is sticky; it dies with the process. Ephemeral session keys and per-boot signer-channel authentication are custody secrets, not durable workflow truth. Rebuilding a recorded binding does not recreate its live route or signing authority.

RecoveryDecision cites an admitted ActionResult or reconciliation observation newer in canonical sequence than the interruption. Policy refuses `retry` without that evidence. A missing result remains unknown until observed; no automatic action is inferred from an inbox/status label.

## Required fault fixtures

Missing executable; caller death; valid-looking text then nonzero exit; final-file-only output; stderr noise; split JSON/UTF-8; newline-free oversized output; hard deadline with endless heartbeat; stale timers; child/grandchild termination; artifact admission failure; crash after artifact before reflection; lost dispatch acknowledgment; duplicate command with conflicting payload. Each checks durable state **and actual process/output behavior** where relevant.
