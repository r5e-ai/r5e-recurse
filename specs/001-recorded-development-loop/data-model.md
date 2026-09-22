# Data model

This is proposed extension vocabulary, not an assertion that these Kinds already exist. Use group `recurse.r5e.io`, version `v1alpha1`, and current schema/ref rules. Kind definitions and associated policies are themselves admitted before instances. Exact machine-readable Kind declarations and conformance fixtures are the first implementation deliverable.

## Common rules

An immutable reference means an admission event reference and, for content, its verified CAS bytes reference. A mutable resource name alone is insufficient for a review target, input version or prior-state comparison. Canonical refs use the existing `{"$ref": "..."}` form; read views may expose convenient strings alongside canonical records. Graph/Node/Task resources are desired intent. Lifecycle observations are events; reducer projections expose status without mutating desired intent.

Every admitted record receives its signer, authority, origin and sequence from the kernel envelope. Descriptive `provider`, `model`, `requestedBy` or `observedPid` fields never replace that actor. Secrets, session private keys and provider bearer tokens are neither fields nor artifacts. Identifiers are opaque IDs scoped to the deployment origin; semantic command IDs are additionally scoped to caller key.

## Records and relationships

| Kind or view | Substrate | Required content and validation |
|---|---|---|
| Graph | Resource | Logical ID, class, objective/definition ref. Class initially `codebase` or `workflow`; no recursive scheduling implied. |
| Node | Resource | Logical ID, Graph ref, objective and acceptance-criteria bytes refs; optional parent Node. Reject cyclic parent linkage in domain validation. Preserve Node across retries. |
| Task | Resource | Logical ID, Node ref, `delegatedBy` orchestrator principal key and admitted `delegationRef`, step (`produce`, `review`, `reflect`, `lesson_review`, `evaluate`, `act`), optional earlier Task event ref and recorded recovery/decision ref authorizing a new attempt. One task is one attempt, not the enduring objective. |
| SessionBinding | Event | Task ref, existing gateway AgentSession resource ref **and its admission event**, session key ID, deployment Badge and orchestrator-to-session Endorsement event refs, boot/run generation, role, actor type (`agent` or `runtime_action`), provider/model for agents and harness/version for both, context-manifest event ref, workspace description/digest, `profile: cooperative-local`, `custody: runtime-held` and `signerReachability: same-user-cooperative-limit`, all required by policy. SessionBinding is signed by the session key and cites deployment Badge plus task delegation in canonical authority; their subjects must match that key. `subject` in Badge and AgentSession admission actor must equal session key; policy verifies this relationship. |
| ContextManifest | Event | Exact rendered input bytes ref, ordered parts with source event/version, content ref, provenance (`operator_instruction`, `policy`, `task_evidence`, `reviewed_lesson`), required flag; projection version, budgets and omissions with reasons; every effective non-secret harness config/instruction digest, override, sanitized-view exclusion and provenance; required custody/profile/signerReachability labels. Auth credentials are referenced separately, not stored or hashed into public manifests. Context parts and rendered input hashes both verified. No ambient CWD sources. |
| Artifact | Event | Type (`work`, `trace`, `review_findings`, `reflection`, `lesson`, `evaluation`), bytes ref/media type, producing session binding when produced by an agent, optional earlier artifact version, parent/source event refs, completeness. Optional `repoAssociation` carries `repoId`, `oid` and `objectFormat`, not a bare commit string across all repos. |
| Review | Event | Exact target Artifact event, criteria ref, reviewer session binding, findings Artifact event, recommendation (`accept`, `revise`, `decline`, `escalate`). Signed by the reviewer session key. Findings contain machine-readable `recommendation`; policy requires the Review recommendation string to equal that exact parsed field (no free-text inference). Reviewer session/provider/key differ from producer; missing reviewer is incomplete coverage, not a recommendation. A findings `revise` paired with Review `accept` is denied. |
| Decision | Event | Exact target Artifact and Review events, disposition, authorized decision actor from envelope, rationale bytes ref. Only the operator-role key or an effective operator-issued decision Endorsement to a reviewer session authorizes a Decision. The delegation names task/target/dispositions/term; review alone grants no decision authority. Runtime custody grants no implicit decision power; the operator can intervene. Routine recommendations do not execute a push or authorize another artifact version. Lesson acceptance may use that explicitly delegated reviewer session key. Milestone acceptance and escalations remain with the operator and cannot be inferred from a routine delegation. |
| LifecycleEvent | Event | Task ref, stable preparation/command ID, optional session binding (required only after binding exists), transition, prior lifecycle event ref, optional output/result refs, reason and observation source. Preparation failure/cancellation can be recorded before a Badge or binding exists. Validity enforced by serialized command handling plus current-state policy before admission; kernel schema alone is not claimed to enforce the state machine. |
| Command | Event | Caller-scoped command ID, command name, canonical payload digest, target, expected prior-state event when applicable. Stable idempotency identity differs from the protocol's one-use signed nonce. Same ID/different payload is refused. |
| RecoveryDecision | Event | Interrupted Task/session, uncertain actions, disposition (`reconcile_only`, `finalize_incomplete`, `retry`), rationale, authorized operator signature and admitted `observationRef` (ActionResult or ReconciliationObservation). Policy refuses retry unless the observation is newer in canonical sequence than the interruption. `retry` authorizes a new attempt; it never turns an old attempt into a successful one. |
| ReconciliationObservation | Event | Interrupted session/action ref, observation method, available evidence refs, observed result/uncertainty, runtime observer signature. Admission sequence establishes that it follows the interruption; it is not proof of all external effects. |
| ManagedRequest | Event | SessionBinding, admitted LlmCall, exact inbound/outbound request-body bytes and digest (managed profile forbids transformation), first-input field path/digest, method/path/upstream/transport, allowlisted semantic headers and operation ID. Session-signed under its Badge; gateway dispatch compares exact bound values. |
| ActionResult | Event | Admitted ToolCall ref, operation ID, observed outcome (`succeeded`, `failed`, `unknown`, `not_dispatched`), result bytes ref, observed repository state when relevant, observation actor. Admission alone never implies execution. |
| Reflection status | Derived | `pending`, `available`, `interrupted`, `unavailable_acknowledged`, derived from artifact/lifecycle/recovery records. An operator can acknowledge absence for incomplete closure but cannot create the missing agent reflection. |
| LessonWithdrawal | Event | Exact lesson Artifact and prior accepting Decision refs, operator-signed reason, optional replacement lesson Artifact. Withdrawal prevents future selection; a replacement needs its own review/acceptance. |
| Lesson eligibility | Derived | Exact lesson Artifact + qualifying cross-provider Review + the operator's accepting Decision. An admitted LessonWithdrawal or explicit accepted replacement prevents future automatic selection without erasing prior use. |
| ReadSnapshot | Derived | Origin, fixed canonical sequence/checkpoint, indexed-through sequence, index version, capture/disclosure scope. Never an independent evidence authority. |

The existing `gateway.r5e.io/v1alpha1/AgentSession` is a signed resource span; preserve that vocabulary for LlmCall/ToolCall references. `SessionBinding` adds orchestration semantics without changing the existing Kind. Reviewer and producer each open their own span under their own key. The runtime service key signs setup/operational records under its own authority; SessionBinding and session-produced acts use the session key and task delegation. The runtime does not impersonate the orchestrator by signing setup. A runtime-observed exit or missing reflection remains an operational observation by the runtime.

Recurse also owns the resource Kind `recurse.r5e.io/v1alpha1/PolicyBundle` with `requiresAuthority: true`. Its admitted source and presentation contract are pinned; `governs` enumerates authorized Kind paths and excludes PolicyBundle itself. Operator activation and management are governed upstream, as specified in [the policy hosting contract](plan.md#accepted-policy-hosting-contract-r5e-245).

## Attempt lifecycle

```text
Task admitted
  -> preparing (context and credential setup)
  -> ready (binding and launch intent admitted)
  -> running (dispatch observed)
  -> reflecting (work/result available or ordinary failure/decline)
  -> completed | declined | failed

preparing/ready/running/reflecting
  -> cancellation_requested -> cancelled (only after observed stop)
  -> interrupted / outcome_unknown (loss of ownership or uncertain effects)
```

Reflection is an independent closure condition. `completed` requires actual reflection and the step's required artifact. Cancellation/failure can remain pending reflection; explicit operator acknowledgment closes an **incomplete** attempt without pretending reflection occurred. A new recovery reflection is produced by a new session, labelled retrospective and linked to the interrupted one. It does not impersonate the original agent. An artifact waiting for review is not “accepted” merely because its producing execution completed.

## Artifact advancement

```text
produced -> review_pending -> reviewed -> accepted | revision_requested | declined | escalated
revision_requested -> new Artifact version -> new independent review -> new Decision
```

Acceptance is derived from the exact target/version's records. Work and exact lesson-version decisions use the operator-role key or the recorded reviewer-session decision delegation. Runtime service custody alone never authorizes decisions. A review finding is never silently upgraded to a decision. A push remains a separate admitted action even for an accepted artifact.

## Concurrency and restart

One command dispatcher serializes mutations for the local deployment. One worker can own a session execution generation consisting of fresh boot ID and run ID. Session keys are ephemeral in-process and are not recovered. Canonical command/lifecycle records carry expected predecessor refs. Recovering the dispatcher reconstructs deduplication and state, refuses pre-boot signer generations, and completes issuer-authorized revocation of unconfirmed session Badges before serving ordinary mutations. A limited observation/revocation path operates during reconciliation. Failure to revoke keeps the mutation gate closed; no recorded SessionBinding revives a live route. The first release supports one active runtime writer; simultaneous runtimes must fail ownership acquisition rather than rely on in-memory locks across machines. Distributed leases/fencing are a later deployment concern.

An admitted launch intent with no durable result is uncertain after restart, whether a PID is still visible or not. Recovery observes/stops the workload within its adapter contract before any explicit retry. A local spool may recover bytes for admission but cannot be treated as evidence until those bytes are admitted. Failure after admission but before acknowledgment is resolved by command identity and canonical history, not by signing another semantic execution.

Canonical policy validation and integration tests must enforce cross-record relationships above. The current kernel's structural schemas do not automatically supply arbitrary state transitions, provider independence or business-level idempotency. The runtime's serialized command boundary enforces those workflow constraints within this managed profile, and the evidence makes its decisions inspectable.

## Preparation and finite reflection

Preparation is durable before SessionBinding exists. A restart can discover an admitted Badge/span with missing binding, record setup interruption against the Task, and reconcile or retire those credentials without launching. No orphan setup record implies launch authority.

An ordinary produce/review/evaluate session reflects before normal terminal closure. A Task whose purpose is `reflect` produces a reflection artifact that itself satisfies that reflection step; it does not recursively start reflect-of-reflect. A lesson may be proposed as a distinct artifact during that reflection step. A later standalone lesson-writing attempt uses step `produce`; in either case its producing session/provider is recorded so lesson review selects the other provider. Retrospective reflection after interruption uses a new Task/session and is labelled as such.

A runtime action Task (`act`) uses a credentialled execution binding but has no model provider: `runtime-git` is an operational harness. It produces an ActionResult and explicit operational assessment; it does not masquerade as an AgentSession that generated a model reflection. The binding records actor type `runtime_action` versus `agent`, with agent-only provider/reflection requirements conditional on that type. The gateway span name remains a protocol span and does not prove a model ran.

## Operator and delegation policy

The operator is the milestone-one orchestrator; the runtime is a custody/execution service principal. A later orchestrator agent needs issuance authority before delegating Tasks. Task.delegatedBy and delegationRef bind that principal to the work. SessionBinding exercises authority issued to its **own** session key: deployment Badge plus task-scoped operator Endorsement. When the orchestrator itself exercises a Badge, preserve it through the Endorsement's parent/resolved chain; do not cite another subject's Badge directly as session authority.

Routine decisions may be delegated to the designated reviewer session by an operator-issued Endorsement scoped to `recurse.r5e.io/v1alpha1/Decision`, exact task/target, allowed dispositions and term. That session's deployment Badge and task delegation must also include Decision; all cited Kind sets intersect. It signs Review and Decision separately; both remain different acts even when the same delegated reviewer signs them. Policy checks findings recommendation equality and independent producer/reviewer identities. A delegated session must record escalations, not accept beyond its scope. Missing, expired or revoked delegation refuses the Decision. Closing the reviewer session destroys its key; a later decision needs a newly authorized session, not credential resurrection.

Task preparation avoids a delegation cycle: the operator first issues a Task-creation Endorsement to the runtime service key scoped to a reserved logical Task ID and Node. Task.delegationRef cites that grant and delegatedBy identifies its orchestrator. After Task admission and ephemeral session-key creation, a separate orchestrator Endorsement to the session key cites that Task in its scope. SessionBinding references both the Task and session delegation. A Task-creation grant is not model/decision authority; credentials for each signer must have that signer as subject.
