# Implementation Plan: Recorded development loop

**Feature**: `001-recorded-development-loop` | **Date**: 2026-09-20 | **Spec**: [spec.md](spec.md)  
**Input**: Local development loop, with session signing and governed pushes from the first milestone.

The feature directory is independent of a Git branch. Planning uses a JJ working copy; no branch, remote push, live deployment or implementation is asserted by this document. Review decisions and delivery status live in Linear.

## Summary

Build one small public OTP application that records a task, supervises a Claude Code or Codex CLI, captures admitted context and immutable output, obtains fresh review on the other provider, records the authorized decision and reflection, and supplies one accepted lesson to a later task. Reuse the kernel for authority and evidence. Extend the gateway's admission integration to use runtime-held session keys under deployment Badges. Managed pushes use structured pre-act ToolCall admission from the start.

The prior-runtime review changes the implementation strategy: reuse its boundaries and regression lessons, not its application umbrella or storage/acceptance semantics. Its Jido integration did useful work, but is not needed for the first two-session workflow. Detailed decisions are in [research.md](research.md).

## Technical Context

**Language/Version**: Elixir `~> 1.19`, OTP 28 initial development baseline, matching the inspected prior-runtime language baseline. Pin exact supported toolchain in the first implementation change.  
**Primary Dependencies**: OTP, Jason, Plug/Bandit for the read facade; existing core/kernel and fold contracts through explicit clients. No Jido, Phoenix or new authoritative database is required. Lock actual versions before implementation acceptance.  
**Storage**: Existing canonical kernel log, resource projection and CAS. Rebuildable in-memory runtime/read indexes initially; local spool files are temporary capture/recovery aids, not canonical authority.  
**Testing**: ExUnit reducer/adapter/contract tests; real-process fixtures; fault injection against an isolated kernel; selected real subscription integration; existing independent verifier and conformance checks for changed protocol surfaces.  
**Target Platform**: Local macOS orchestration and a development gateway/kernel deployment. Linux adapter compatibility is planned through the same process contract; container/Kubernetes enforcement is milestone two.  
**Project Type**: OTP application with CLI control/inspector and authenticated loopback HTTP reads. Gateway signing integration is a coordinated change in enterprise; core changes are not assumed.  
**Performance Goals**: Correctly sustain two active sessions and inspect 10,000 indexed events; page reads at that scale target p95 under one second on the development machine, measured excluding unavailable payload downloads. This is a local acceptance target, not a fleet capacity claim.  
**Constraints**: Hard run timeout and bounded context/output; no blind effect retry; no private-key or upstream-token logging; subscription routing is a live acceptance gate; public specs remain self-contained.  
**Scale/Scope**: One operator/deployment, two active agent sessions maximum initially, isolated working directories, one producer/reviewer pair per workflow step, no automatic recursive decomposition or fleet startup.

Initial per-task configurable budgets (record overrides in the admitted task/launch context): a default 30-minute hard execution limit, five-minute idle-output limit, 5-second graceful termination then 5-second escalation observation, 8 MiB per captured CAS chunk, 64 MiB total trace budget including inbound request bodies on every call, responses and exposed CLI output (CAS deduplication does not reduce counted capture volume), 512 KiB supplied context byte ceiling plus the selected model's known token budget. These are proposed operational defaults, not model capability assumptions. Required context exceeding either limit refuses launch; optional omissions are recorded. Hitting capture limits stops the managed session with incomplete capture rather than silently dropping the remainder. Hard timeout does not extend on output. UI/status uses observed process outcomes, not timeout expiry alone.

## Constitution Check

The public Charter and core specifications govern protocol claims; [existing architecture](../../docs/architecture.md) governs Recurse's semantics. Private Spec Kit memory summarizes these constraints and the operator's staged scope. The archived enterprise constitution is not imported as a new constitution for this repository.

| Gate | Design before research and after interface design |
|---|---|
| Canonical authority and pre-act policy | Existing kernel admission/CAS; no competing durable authority. Launch, managed model requests and push have explicit pre-dispatch admission boundaries. |
| Graph/Node/Task/session/artifact distinction | New attempts preserve Node and create new Task/session; controllers only derive status and never rewrite desired spec. |
| Independent review and reflection | Fresh different-provider/key/session, exact artifact binding, distinct review and decision; reflection before normal closure; lesson version requires the operator role or its recorded decision delegate to accept it. |
| Keys and house credentials | Runtime custody explicitly disclosed; two-signature Badge and signed request authority used. No autonomous self or hardware-root claim. |
| Legible mediation and privacy | Explicit roles/input provenance; no producer private-context inheritance; private payloads by default; disclosure is separate. |
| Anyone can verify | Canonical bundle, explicit pins/posture and verifier limitations; read facade and viewer cannot replace verification. |
| Honest staged guarantees | Local cooperative profile discloses no host containment or externally anchored completeness. Stronger witness remains milestone two; full Charter conformance is not asserted. |
| Review before dispatch | Independent scope/design review and its required corrections precede task generation and dispatch. The designated reviewer generates Spec Kit tasks and syncs Linear; analysis precedes implementation. Linear is the progress authority. |

These gates pass as a bounded design review, with the staged departures below explicit. They are not operational test results. Live provider routing is unproven; source-port licensing must be settled before any direct copy. Neither is hidden by selecting a mock.

## Principals and Charter commitments

The operator principal is the orchestrator in milestone one. The OTP runtime supplies scheduling/execution and key custody as a service principal; it does not acquire authority by supervising a process. Task.delegatedBy and task delegation link the orchestrator to each session. SessionBinding cites session-subject deployment and operator authority, preserving any operator Badge through the delegation chain. Routine decisions, including lesson acceptance, can be delegated to the designated reviewer session through an admitted decision-scoped Endorsement. Milestone acceptance and escalations stay with the operator. A policy-selected reviewer name is not a substitute for this recorded grant.

Against the Charter's six lines: line 1 requires inspectable implementation/build/policy and explicit private content; line 2 requires independent offline verification; lines 3 and 6 require honest house credentials without claiming issuer-owned keys are autonomous selves; line 5 requires recorded, scoped conditions and legible mediation, including the user's task constraints and deployment rules. Tests must enforce the stricter applicable conditions, not only print labels. For line 4, milestone one preserves append-only canonical history and supersession but does **not** complete roots anchored beyond the operator's reach. That anchoring is milestone two. The `r5e-recurse` name identifies the development project; this local profile is not a certification of full Charter conformance or authorization to market an independently anchored witness. The plan does not waive the Charter naming rule.

## Project Structure

### Documentation

```text
specs/001-recorded-development-loop/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── execution.md
│   ├── session-admission.md
│   ├── managed-push.md
│   └── read-api.md
└── checklists/
    └── requirements.md
```

`tasks.md` is generated by the later Spec Kit tasks phase after scope/design review. It is not a completion log. Source and acceptance artifacts below are proposed; this planning change does not create them.

### Proposed source layout

```text
lib/r5e_recurse/
  application.ex
  lifecycle.ex
  commands.ex
  reconcile.ex
  kernel_client.ex
  context.ex
  review.ex
  reflection.ex
  session_keys.ex
  execution/
    adapter.ex
    supervisor.ex
    local_cli.ex
    claude_code.ex
    codex.ex
  actions/git_push.ex
  read/index.ex
  read/router.ex
lib/mix/tasks/recurse.ex
priv/kinds/
priv/policy/
test/contract/
test/execution/
test/integration/
test/fixtures/
```

**Structure decision**: One application, pure lifecycle/domain functions and small execution/evidence boundaries. Framework integration is behind an adapter if needed later. Existing inspectable gateway/fold source remains in the enterprise source distribution; reusable signing/binding/admission implementation must ship in that public distribution or a public shared module, never solely in private deployment tooling. Enterprise-private material is limited to operator configuration, secrets and deployment wiring; session signing is integrated there rather than implementing a second model proxy inside Recurse. Kind declarations are new extension vocabulary admitted through the existing kernel, not changes silently made to existing public Kind definitions.

## Phase 0 — Research decisions

[Research](research.md) records ten decisions and alternatives. The prior runtime had implemented useful lifecycle/session separation, Port streaming, context parts, GAN target lineage and message deduplication. It did not implement the required session signing, safe effect recovery, independent acceptance, real reflection or accepted lessons.

Codex subscription configuration has an official supported proxy path, but the local assessment found no gateway on the documented listener and no selected ChatGPT upstream. Provisioning an isolated, explicitly selected test gateway is the first implementation integration step. Do not send a ChatGPT bearer to the shipped Anthropic fallback. Claude's live path and both refresh behaviors also require actual evidence. Neither documentation nor historical tests substitutes for these results.

## Phase 1 — Design

- [Data model](data-model.md): immutable definitions and events, attempt identities, state reduction and authority.
- [Execution contract](contracts/execution.md): command idempotency, supervised process lifecycle, context/output, cancellation and uncertainty.
- [Session admission](contracts/session-admission.md): runtime custody, Badge issuance, exact request signing and gateway correlation.
- [Managed push](contracts/managed-push.md): structured values, policy, dispatch and reconciliation.
- [Read API](contracts/read-api.md): task-oriented queries with canonical references and stable coverage.
- [Acceptance walkthrough](quickstart.md): runnable evidence to produce during implementation, with current missing implementation stated explicitly.

## Phase 2 — Implementation decomposition for subsequent task generation

| Slice | Deliverable and dependencies | Exit evidence |
|---|---|---|
| A1 — live baseline | Designated kernel/gateway test deployment; explicit ChatGPT upstream; pinned Claude and Codex subscription configuration. Independent of runtime implementation. | Credential-safe real round trips and route/receipt correlation, or a precise live-path blocker. Test adapters remain labelled. |
| A2 — vocabulary and canonical client | Admit extension definitions, scope/policy, command identity and pure reducers. Uses current kernel protocol; no old DB transplant. | Contract fixtures for grants/denials, duplicate semantic command/conflicting payload, replay from canonical records, loss after admission response. |
| B1 — session identity | Ephemeral runtime key custody, operator delegation, deployment-issued Badge, immutable session binding and spec-bytes signer path; per-boot channel authentication/revocation and lost-ack nonce journal. Depends on A2. | Wrong-key, expired/revoked Badge, changed request, replay and swapped-session tests; session signer visible on actual managed admissions. |
| B2 — supervised execution | Explicit context/effective harness config, isolated home/config and per-writer directory, temporary CLI worker, framed output, hard/idle timeouts, durable artifact and reflection-pending state. Depends on A2/B1. | Both fake-adapter fault suite and live bounded sessions. Nonzero exits, capture limits and missing executables never become success. |
| B3 — recovery and cancellation | Recovery command and reconciliation; process ownership and stop observation. Depends on B2. | Child/grandchild heartbeat cancellation; crash after artifact; no unapproved replacement execution; uncertain effect reconciliation. |
| C — review and lesson | Fresh cross-provider review, separate authorized decision, real reflection and accepted lesson into later task. Depends on B2/B3. | Accept/revise/decline/escalate fixtures and real cycle; changed version re-reviewed; recorded delegated or operator exact lesson acceptance; later outcome recorded. |
| P — managed push | Structured ToolCall and result, destination allowlist and exact OID dispatch. Depends on A2/B1/B3; can develop alongside C. | Disposable remote allowed/refused cases, mutable-ref race, lost-response reconciliation and zero automatic push retry. |
| D — independent reads | Snapshot-labelled projection and HTTP facade begin with A2; extend through B/C/P. | Facade and bundle-only lineage reconstruction/diff, index omission detection/rebuild, stable pagination, revision links and coherent bundle/reference-verifier result. |
| E — optional disclosure | Select intended public evidence only after local cycle; independent viewer may consume D. | Explicit disclosure selection, withheld-payload limitations, unchanged signed bytes. Public witness/root/anchoring remain milestone two. |

Spec/plan are the initial candidate artifacts for later admission by the loop. That later admission records the actual event sequence; it does not backdate how these files were created.

## Validation and requirement coverage

| Checks | Requirements | Required observations |
|---|---|---|
| Live routing and signature binding | FR-002,004–006 | Both subscription paths; exact raw request, span and Badge; no fold-only actor substitution; allowed and refused supported calls. |
| Context and lifecycle | FR-001,003,007–009,012,024 | Explicit roots/versioned inputs; honest omissions; distinct attempts; process/output observations; reflection incompleteness preserved. |
| Independent review and learning | FR-010–014 | Producer/reviewer key/session/provider distinct; immutable version; decision actor; operator or recorded delegate accepts lesson; later criterion-based result. |
| Governed pushes | FR-015–016 | Exact destination/OID; admission before dispatch; refusal no remote effect; crash uncertain, no blind replay. |
| Canonical reads/exports | FR-017–020 | Kernel replay, index loss/rebuild, coherent snapshot, two clients, reference verification. |
| Privacy and stated scope | FR-021–024 | No automatic disclosure; credentials absent; custody/scope present; original genesis and reader pins preserved. |

Regression fixtures explicitly carry forward prior failure lessons: nonzero exit with valid-looking output; final-file-only output read before cleanup; split JSON and UTF-8; stderr separation; stale timeout delivery; hard cap despite continuous output; owner death; subscriber restart/catch-up; admission persistence failure; identical idempotency key with changed payload; unknown external result; missing required review; incomplete reflection. Fake tests do not establish live provider compatibility or persisted recovery. Run isolated canonical integration tests before claiming those results.

## Complexity Tracking

| Staged departure | Why needed | Stronger alternative deferred |
|---|---|---|
| Cooperative CLI on local host instead of projected world | First useful orchestration loop; capture and managed authority are explicit. Host-wide enforcement is not claimed. | Contained/projected execution needs separate OS/deployment controls and broader tool mediation; milestone two. |
| Runtime-held session keys rather than autonomous self custody | Deployable house credentials supported by current Badge protocol; custody is part of every session record. | Identity-r2 self, hardware-root ceremony and independent agent custody are later changes through this pipeline. |
| Local coherent evidence rather than an independently anchored public witness | Makes the development loop inspectable and offline-verifiable without waiting for public operations. | External anchors, published checkpoint history and root linkage are milestone two. |

These are scoped implementation stages authorized by the milestone, not amendments weakening the Charter or permission to market the local profile as a complete witness. The plan ends at design and decomposition. The designated reviewer owns task generation and Linear synchronization after folding the review corrections; Spec Kit analysis precedes implementation dispatch.

The enterprise integration is a separately tracked deliverable: managed binding registry, authenticated signer bridge, ManagedRequest admission, nonce-lookup recovery and disabled managed retries. It must have its own public enterprise issue linked from the generated implementation tasks; a runtime-only task cannot silently stand in for that cross-repository work.
