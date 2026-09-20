# Feature Specification: Recorded development loop

**Feature directory**: `specs/001-recorded-development-loop`  
**Created**: 2026-09-20  
**Input**: Local development with Claude Code and Codex, recorded session authority, independent review, reflection and a reviewed lesson supplied to later work. Managed pushes are admitted before execution. This loop is milestone one and the means of building the stronger witness in milestone two.

Delivery status and review decisions belong in Linear. This document specifies intended behavior; it does not assert that the feature exists or has passed acceptance.

## Roles

The operator holds the orchestration role. Routine work/lesson decisions may be delegated by an admitted Endorsement to a designated reviewer session, scoped to decision Kinds, task/target, dispositions and term. Milestone acceptance and escalations remain with the operator. References to operator approval below include a qualifying recorded delegate for routine decisions only. The runtime is a service custodian/signer and executor, not the orchestrator or an implicit decider. These are required authority relationships to establish, not a claim that delegation has already occurred.

## User Scenarios & Testing

### User Story 1 — Delegate a bounded task and inspect its record (Priority: P1)

The operator supplies a development task, acceptance criteria and selected context. The operator chooses a supported agent and can follow its progress, retrieve its output, and distinguish what the system captured from what it could not observe.

**Why this priority**: This is the first useful replacement for manually transferring work between conversations.

**Independent Test**: Run one bounded task separately with each supported agent. Retrieve the supplied context, session credential, output and terminal result without consulting private agent memory.

**Acceptance Scenarios**:

1. **Given** an authorized task with explicit inputs, **when** execution starts, **then** its recorded session identifies its task, provider, model, harness version, authority and supplied context before work begins.
2. **Given** a managed session, **when** a supported model request is made, **then** admission precedes forwarding and the record ties the exact request to the session key and its deployment-issued Badge.
3. **Given** an expired or revoked session credential, **when** another managed request is attempted, **then** no corresponding upstream act is dispatched and the attributable refusal is retrievable.
4. **Given** a completed task, **when** the operator inspects it, **then** the immutable work artifact, exposed trace and recorded outcome remain distinguishable. A reported error cannot appear as successful completion merely because output exists.

### User Story 2 — Recover or stop work without silently running it twice (Priority: P1)

The operator can cancel work and restart orchestration after failure without losing admitted artifacts or unknowingly repeating an external action.

**Why this priority**: A supervisor that restarts a process must not accidentally repeat the work it was doing.

**Independent Test**: Use a controlled task that produces an artifact and then waits. Cancel one run; crash orchestration during another. Observe the managed process as well as the durable record.

**Acceptance Scenarios**:

1. **Given** a running session, **when** the operator cancels it, **then** the cancellation request and observed termination are recorded separately. An unconfirmed stop is shown as unconfirmed, not cancelled.
2. **Given** an admitted artifact and no normal completion, **when** orchestration crashes and restarts, **then** the artifact is retrievable, the attempt is interrupted or requires reconciliation, and no new execution starts automatically.
3. **Given** interrupted work, **when** the operator explicitly authorizes a retry, **then** a new Task and AgentSession refer to the previous attempt under the same logical Node.
4. **Given** an external action with an uncertain result, **when** recovery runs, **then** it records uncertainty and the RecoveryDecision cites an admitted observation newer than the interruption; policy refuses retry without that observation.

### User Story 3 — Obtain independent review and decide what advances (Priority: P1)

The operator receives a review from the other provider against the exact artifact and acceptance criteria, with an explicit accept, revise, decline or escalate result.

**Why this priority**: The record must show why work was accepted and which version was actually reviewed.

**Independent Test**: Give a fresh reviewer an immutable fixture artifact and criteria. Demonstrate both an accepted artifact and one requiring revision or refusal.

**Acceptance Scenarios**:

1. **Given** a producer artifact, **when** review begins, **then** the reviewer has a different session key and provider and receives only the explicit review context, including the artifact and criteria. The producer's private conversation is not inherited, and isolated harness configuration prevents ambient/project instructions or hooks from becoming unrecorded review inputs.
2. **Given** a review requiring revision, **when** a changed artifact is submitted, **then** it requires a new review; the earlier review cannot authorize the changed version.
3. **Given** a review result, **when** an authorized decision is recorded, **then** the record distinguishes the reviewer's recommendation from the decision and its actor. The operator can intervene or decline the work.

### User Story 4 — Learn from reviewed experience (Priority: P1)

The operator can see a session's reflection, review a proposed lesson, and deliberately supply an accepted lesson to later work.

**Why this priority**: This closes the first learning loop without claiming that every generated lesson is useful.

**Independent Test**: Start from a recorded task and reflection; have the other provider review a proposed lesson, obtain the operator's acceptance of that version, and supply it to a later task with explicit evaluation criteria.

**Acceptance Scenarios**:

1. **Given** completed, declined or failed work, **when** finalization occurs, **then** a distinct reflection artifact or an honest incomplete-reflection record is present. A system-generated status message is not attributed as agent reflection.
2. **Given** a proposed lesson, **when** it is selected for reuse, **then** its exact version has independent review and the operator's recorded acceptance; unaccepted or superseded versions are not selected implicitly.
3. **Given** an accepted lesson, **when** later work receives it, **then** the supplied context cites that version and the later result is compared with the stated criteria. Negative and inconclusive outcomes remain visible.

### User Story 5 — Govern a managed push (Priority: P1)

The operator can authorize the runtime to push reviewed work to an allowed branch, with the requested repository, destination ref and exact revision recorded before the push.

**Why this priority**: Pushing is a consequential action, even before freight-membership enforcement exists.

**Independent Test**: Use a disposable repository and remote. Admit one allowed branch push and refuse a protected-ref push; inspect both the chain and the remote refs.

**Acceptance Scenarios**:

1. **Given** an exact push proposal permitted by the current policy, **when** the runtime pushes, **then** admission occurs first and the dispatched repository/ref/revision equal the admitted values. The later result is recorded separately.
2. **Given** a push to `main` under the initial branch-only policy, **when** it is requested, **then** a refusal is recorded and the remote does not change.
3. **Given** an admitted push with a lost response, **when** orchestration restarts, **then** it does not push again automatically; reconciliation distinguishes observed remote state from proof of who changed it.

### User Story 6 — Inspect history through an independent client (Priority: P1)

The operator or another authorized reader can follow a task from context through artifact, review, decision and reflection using a documented read interface, and verify available canonical evidence independently.

**Why this priority**: The recorded loop must be inspectable outside the orchestrator and its chosen UI.

**Independent Test**: An independent reader reconstructs a completed task from the exported bundle alone, then compares canonical lineage with the documented facade response.

**Acceptance Scenarios**:

1. **Given** recorded work, **when** a reader looks up its task, session or associated repository/revision, **then** the response identifies the source chain, covered checkpoint, captured scope and relevant evidence links.
2. **Given** concurrent new records, **when** a reader paginates an existing snapshot, **then** ordering and coverage remain stable without omitted or duplicated records within that snapshot.
3. **Given** private or unavailable payloads, **when** evidence is read or exported, **then** omissions and their verification implications are explicit. Public disclosure never silently rewrites signed content.

### Edge Cases

- Provider authentication fails or refresh is required; one provider cannot route through the gateway.
- The CLI exits unsuccessfully after producing apparently useful text; it hangs while emitting output; its final output exceeds the configured limit or arrives in fragments.
- A child process survives its immediate parent; the system cannot confirm its termination.
- Admission succeeds but its response is lost; dispatch succeeds but its result cannot be recorded.
- A fixture checkout or ambient home contains a marker-writing hook/instruction file; isolated reviewer execution must not run it or load its instructions. A reviewer lacking task evidence may decline or escalate.
- A session credential expires mid-run; a copied session identifier or credential is presented for a different session.
- A lesson changes after review; the referenced payload is missing; the configured context budget is exceeded.
- A repository's local branch or remote destination changes between proposal and dispatch.
- A reader asks for a stale snapshot, deleted payload or revision never associated with recorded work.

## Requirements

### Functional Requirements

- **FR-001**: Preserve separate Graph, Node, Task, AgentSession and immutable Artifact identities; Task records its orchestrator principal (`delegatedBy`) and admitted delegation; retries create new Tasks and sessions linked to earlier attempts, retaining the logical Node.
- **FR-002**: Support managed Claude Code and Codex sessions through the gateway using the selected subscription authentication modes. A mock, historical import or alternative billing mode cannot satisfy this requirement.
- **FR-003**: Record exact supplied context, source versions, provenance labels, explicit omissions and selection reasons before execution. Capture exposed session output separately; do not claim access to hidden cognition or unsupplied desktop history. Required custody/profile fields and the effective harness configuration inventory make the captured boundary testable.
- **FR-004**: Bind every managed session to a distinct signing key held by the runtime and a deployment-issued, subject-countersigned Badge. Record custody, provider, harness and role; do not describe the Badge as an autonomous self.
- **FR-005**: Require supported managed model requests to be signed for the session, cite its effective Badge and bind the admitted request to what is forwarded. Metadata or a fold-service signature alone is insufficient session attribution.
- **FR-006**: Record attributable denials, admission outcomes and supported external results distinctly. Unattributable malformed requests and transport failures must not be presented as canonical signed acts.
- **FR-007**: Permit cancellation, record its request and observed result, and disclose uncertainty about unmanaged descendants or incomplete termination.
- **FR-008**: Recover admitted state and artifacts after restart without automatic execution replay. Require an explicit recorded recovery decision before starting a new attempt or repeating an uncertain external action.
- **FR-009**: Give each writing session its own working directory and every session isolated home/configuration. Reviewers receive an immutable artifact or read-only view with project/global instruction and hook auto-loading suppressed. Record every effective non-secret harness configuration digest and exclusions.
- **FR-010**: Require a fresh session on the other provider to review the exact artifact version against explicit criteria. Record reviewer provenance and all intentionally shared inputs, including effective harness configuration. Verify isolation with a marker-writing hook fixture, not a model-behavior assumption.
- **FR-011**: Record accept, revise, decline and escalate recommendations separately from authorized decisions. The findings carry a machine-readable recommendation; the reviewer session signs Review, and policy denies a recommendation differing from the findings. Decision authority is an operator role or recorded decision delegation. A changed artifact requires new review before advancement; the operator can intervene.
- **FR-012**: Require a distinct reflection step before normal workflow closure. Record missing or interrupted reflection honestly; never fabricate reflection on behalf of a crashed agent.
- **FR-013**: Represent proposed lessons as versioned artifacts with source reflection links, independent review and acceptance of the exact version by the operator or its recorded decision delegate before reuse.
- **FR-014**: Cite the selected lesson in a later task's supplied context and record its evaluation against explicit criteria, including negative or inconclusive results.
- **FR-015**: Route all pushes performed by this managed workflow through runtime admission of the exact repository, ref and revision before dispatch. Agents request pushes from the runtime rather than issuing them directly. Record allowed and refused requests and any later execution result.
- **FR-016**: Initially allow only explicitly configured repository/branch destinations and refuse `main`, deletion, force and broad ref pushes. A freight-membership rule and forge-side enforcement are later work. Merges occur on the forge outside this managed push loop.
- **FR-017**: Preserve canonical admission and evidence history as authority. Rebuilt operational state must identify its source history; a mutable local status or search index cannot substitute for an admitted decision.
- **FR-018**: Provide a versioned read interface for tasks, sessions, ordered events, artifact and review links, reflections, and recorded repository/revision associations. Expose stable pagination and checkpoint coverage.
- **FR-019**: Provide a minimal inspector and demonstrate a second independent reader that reconstructs lineage from the exported bundle without facade calls, then compares it with facade source references. Readers must not need private agent memory, database access or a particular UI framework.
- **FR-020**: Export a coherent canonical evidence snapshot for independent verification with explicit reader trust and posture. Disclose missing evidence and verifier limitations; do not label a mutable live export coherent without checking it.
- **FR-021**: Keep full transcripts and credentials private by default. Public disclosure is separately selected and authorized; signed bytes are never edited to produce a sanitized original.
- **FR-022**: Expose actual execution and evidence coverage. Policy requires `custody: runtime-held` and `profile: cooperative-local` on managed bindings/context; derived views preserve those fields. Their labels state scope and must not imply host containment, capture of every action, hardware custody or cognitive independence.
- **FR-023**: Preserve prior genesis history and existing trust semantics. Hardware-root linkage, autonomous identity, external anchoring and the public witness remain subsequent work.
- **FR-024**: Make mediation legible: tell each agent its role, supplied context, governing conditions and available tools without deceptive prompts or fabricated evidence. The first ManagedRequest must contain the ContextManifest rendered input verbatim in its decoded provider input string; equality is checked before forwarding.

### Key Entities

- **Graph / Node**: A collection of logical work and a stable work objective.
- **Task / AgentSession**: One workflow-step attempt and its agent execution, authority and context.
- **Context manifest**: The exact inputs supplied, their sources and versions, and explicit exclusions.
- **Artifact**: Immutable work, trace, reflection or lesson content with lineage and availability.
- **Review / Decision**: An assessment of an exact artifact and an authorized disposition of it.
- **Badge**: A deployment-issued credential countersigned by the session key; authority with an explicit term and scope.
- **Managed action / Result**: An admitted request to act and a separate observation of execution, failure or uncertainty.
- **Recovery decision**: Explicit permission to reconcile, finalize or start a new attempt after interruption.
- **Read snapshot**: A fixed evidence boundary and the derived information known through it.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Both supported agents each complete at least one real managed task through the selected subscription path; every demonstrated request has retrievable session-bound admission evidence.
- **SC-002**: One real development task (a non-fixture task whose resulting artifact is later pushed through the managed push path) completes production, fresh cross-provider review, decision and reflection; a second branch demonstrates revision or decline and the operator's intervention.
- **SC-003**: One independently reviewed, operator-approved lesson is supplied to a later task by exact version, with a recorded evaluation outcome.
- **SC-004**: Cancellation and a crash after artifact creation are demonstrated independently. Restart preserves the artifact and starts zero unapproved replacement executions; uncertain actions remain visibly unresolved until a recorded decision.
- **SC-005**: An allowed branch push and a refused protected-ref push show matching pre-act evidence and remote observations; the refused operation changes zero remote refs.
- **SC-006**: A facade reader and an independent bundle-only reader reconstruct the same demonstrated lineage at one checkpoint; the latter makes no facade calls during reconstruction, then diffs canonical edges/source refs against the facade and detects an intentionally omitted edge. The available bundle passes the reference verifier under explicit reader settings, with all limitations retained.
- **SC-007**: Every demonstrated managed binding/context has policy-validated custody/profile fields, with reads preserving their source references; zero private payloads or credentials are published without a separately recorded disclosure decision.

## Assumptions

- The first deployment serves the operator on a local machine with cooperative agents. It is an orchestration milestone, not a hostile-agent containment claim.
- The recorded loop is milestone one. Milestone two builds the boundary, freight-bound push, publicly anchored chain, autonomous identity revision and canonical console through that loop.
- Both selected subscription paths are mandatory acceptance dependencies. A blocked live path permits contract and test-adapter development, but does not reduce the milestone silently.
- Exact numeric resource budgets and implementation choices belong in the plan and are visible to operators; they do not expand the target to a fleet scheduler or frontier training platform.
- Existing protocol admission, verification and content storage are reused. Necessary extension vocabulary and integration changes are part of this feature.
- Public viewing and automated publication are optional later deliverables. Existing desktop conversations are not implicitly managed sessions.
- These specification artifacts can be admitted and reviewed by the loop after it exists; their initial authorship is not retroactively represented as governed execution.
