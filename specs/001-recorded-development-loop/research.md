# Research decisions: recorded development loop

This design incorporates source, tests, review notes and revision history from the earlier runtime. Its inspected revision was `b5c2fa957217f942dc12117b987ff825cda5ee80`; the archived conceptual design was inspected at `21d60c397c9514ecb3a5ea4469d13877c034f06b`. Those sources are prior art, not dependencies required to read or implement this specification. Detailed operator research remains private. No old source is copied by this feature's planning artifacts.

The assessment inspected test assertions but did not execute the old application or database suite. Historical pass reports are not current verification. The new live two-provider path remains an acceptance dependency, not an assumed research result.

## R1 — Subscription routing is the first integration gate

**Decision:** Use each CLI's supported endpoint configuration and existing selected subscription authentication. Start with HTTP streaming; test WebSockets only if later selected. An isolated ChatGPT upstream configuration precedes sending any subscription credential.

**Rationale:** Installed Codex 0.149.1 reports ChatGPT login and supports a custom provider. Official [authentication documentation](https://learn.chatgpt.com/docs/auth) supports `requires_openai_auth = true` through an LLM proxy, while the [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) describes Responses and transport settings. Documentation establishes a candidate, not successful routing on this deployment. The gateway source supports `/backend-api/codex/responses`, but its shipped loopback fallback selects Anthropic and its seeds do not configure a ChatGPT subscription upstream. Endpoint selection must be verified before forwarding a bearer credential.

**Alternatives considered:** API-key substitution fails the specified billing/authentication requirement. A direct provider call or imported trace fails gateway admission. TLS interception is unnecessary as the first option and is not part of this plan.

**Exit evidence:** Pinned client versions, selected authentication mode, credential-safe effective configuration, incoming path, selected upstream, request/response correlation, admission evidence and a successful real response for each CLI. Refresh handling is separately exercised or visibly remains unverified. The current assessment has not completed either live acceptance run; contract development can proceed, milestone completion cannot.

## R2 — Small OTP application, with Jido deferred deliberately

**Decision:** Build one public `:r5e_recurse` OTP application with a pure lifecycle reducer, supervised temporary execution processes and explicit adapter behaviours. Do not add Jido to the first slice.

**Rationale:** The prior runtime successfully separated durable problem data from Jido NodeSession and moved work through AgentServer. Its CLI process was already a plain GenServer/Port; Jido was useful for named agents, actions and thread/memory hooks, but did not supply canonical authority, workflow policy or process containment. This milestone needs two role-specific sessions and explicit handoff, not its fleet/startup machinery. Keeping the narrow execution interface permits Jido or a native model loop to be introduced with evidence later.

**Alternatives considered:** Importing the umbrella brings a second persistence model and automatic idle work. A full framework rewrite spends effort on interfaces not needed for this loop. Retaining Jido immediately adds hooks that must be reconciled without removing the critical integration work.

## R3 — Preserve the planes; use the kernel as authority

**Decision:** Admit desired resources and immutable lifecycle/evidence events through the current kernel. Derive runtime state and read indexes from the log; keep session processes disposable. Use CAS for exact artifact bytes. No authoritative Postgres workflow store is added.

**Rationale:** Prior persistence could return success with persistence disabled or after an append error. Its mutable artifact rows could accept a supplied hash without verifying the bytes. Its graph queries offered useful vocabulary but no coherent snapshot across changing rows. Current kernel resources are already replayed from canonical events, so a second authority would add reconciliation problems.

**Alternatives considered:** Reuse Ecto tables as authority — rejected. Use them later as replaceable indexed projections — possible after a measured need. Treat a broadcast as durable acknowledgment — rejected.

## R4 — Recovery is reconciliation, not automatic rerun

**Decision:** Record command identity, payload digest, attempt identity and dispatch boundary. After restart, unfinished attempts enter reconciliation. Re-execution requires an explicit recorded decision and new Task/session under the existing Node. Temporary execution children never restart model work automatically.

**Rationale:** Prior RPC fallback could run a mutation locally after an uncertain remote result. Message deduplication did not close the crash window after an external effect. Historical permanent subscribers repeatedly restarted against dead owners; a later temporary-child fix addressed that real failure. Bus restart tests established live delivery, not replay completeness.

**Alternatives considered:** Exactly-once external action claims — rejected. Blind RPC retry — rejected. Resume live output with no durable ownership check — rejected. An orphaned workload is stopped/reconciled or reported unknown, never called successfully cancelled solely from a PID lookup.

## R5 — Reuse context and review structure, replace their authority semantics

**Decision:** Retain a structured context request/part/renderer boundary and explicit target → context → findings lineage. Capture exact inputs plus a provenance/omission manifest. Separate producer, reviewer, decision, reflection and lesson versions.

**Rationale:** The prior context projection was a useful decomposition but read ambient working-directory files, used a stale absolute source path, dropped part metadata and silently omitted unsupported parts. Its GAN review captured target/context/findings but could complete with partial reviewers; its workflow verifier could use the producer model and mark work done directly. None establishes independent acceptance.

**Alternatives considered:** Inherit an entire producer conversation — rejected. Treat partial review as sufficient mandatory review — rejected. Hash rendered text alone and discard source versions — rejected. Retain an advisory inbox later as a derived projection — compatible but unnecessary now.

## R6 — Reflection and lessons require new implementation

**Decision:** Require a real reflection artifact, or a distinct interrupted/missing record when it cannot be obtained. A lesson is an immutable artifact with its own cross-provider review and acceptance by the operator or an explicitly recorded decision delegate before selection into later context.

**Rationale:** The old workflow emitted completion first, then a generated status sentence named reflection. It did not implement reviewed lessons. Thread/memory snapshots were useful traces but were not equivalent to agent reflection. Captured inputs allow inspection and reruns; they do not guarantee deterministic model output or improvement.

**Alternatives considered:** Rename status text reflection — rejected. Automatically append all reflections to future context — rejected. Require measurable quality improvement on every run — rejected; record the experiment's outcome, including failure.

## R7 — Signed session admissions need an explicit gateway integration

**Decision:** Runtime custody creates one ephemeral in-process Ed25519 key per session; restart never restores old signing capability. A deployment authority issues a term-limited Badge, countersigned by that key. Managed request admissions use that session signer, cite the Badge and task-scoped orchestrator Endorsement; gateway service observations remain separately attributed. See [session admission contract](contracts/session-admission.md).

**Rationale:** Existing fold admissions always use the fold role key. The existing gateway AgentSession Kind can represent a signed span but does not contain the required task, context and custody binding; add an immutable orchestration binding referencing that span. The current protocol already supports Badge, signed requests and authority resolution. No identity-r2 or hardware ceremony is needed to implement this narrower house credential.

**Alternatives considered:** Merely record an account header or session string — fails authentication. Pass raw session private keys to CLI adapters — unnecessary. Call an operator-held key an autonomous agent self — false. Silently re-sign a fold receipt after execution — not pre-act admission.

## R8 — Push admission now, freight membership later

**Decision:** Runtime acts as a custody/execution service, pushing from a runtime-owned bare repository with a distinct deploy key through a structured `git.push` operation with configured repository identity, exact commit OID, fully qualified destination ref and expected remote state. Reuse gateway ToolCall admission with structured arguments; record results separately. Default policy allows configured branch destinations and rejects main, deletion, force and multi-ref pushes.

**Rationale:** A shell-text match does not bind what Git moves. Admission must govern the values actually used, and an uncertain response cannot safely cause a retry. Existing contributor controls remain useful but do not supply this evidence.

**Alternatives considered:** Add forge-wide enforcement now — deferred by scope. Require freight membership now — milestone two. Claim a cooperative host agent cannot bypass its instructions — rejected; the managed adapter disables/restricts direct push surfaces where supported and records the coverage limit.

## R9 — Read contract alongside execution, no viewer dependency

**Decision:** Supply a loopback authenticated HTTP read facade with fixed-snapshot pagination over canonical events, plus a small inspector. Derived views identify chain origin, checkpoint and indexed sequence. A reader can retrieve canonical references and run the existing verifier independently; acceptance additionally reconstructs lineage from the bundle without querying the facade and detects index omissions.

**Rationale:** Prior queries lacked general snapshot coverage and could misstate pagination completion. The existing kernel offers resources, events, CAS and export primitives, but not this task-oriented facade. Its reviewed live export has a snapshot race; initial export must use verified quiescence or a corrected snapshot path.

**Alternatives considered:** Make Phoenix UI state the record — rejected. Build a separate public viewer before the loop — deferred. Present a disclosed subset as an undisclosed complete bundle — rejected.

## R10 — Porting evidence and dependencies

**Decision:** Use the prior design and regression cases to write the first implementation against current contracts. Any later direct source port records original revision, file attribution and licensing before public inclusion.

**Rationale:** The prior root inventory did not establish a source license. Access to a checkout is not enough to settle publication rights. Its pinned framework versions were Jido 2.2.0, Jido Action 2.2.0, Jido AI 2.1.0 and Jido Signal 2.1.1; these are historical facts, not new dependencies. No vendor code or private review trace is brought into the public feature.

**Alternatives considered:** Copy first and resolve origins later — rejected. Repeat all historical research from scratch — unnecessary; the recorded failure cases are part of the validation plan.

## Public protocol baseline

Design inspected against these public revisions; integration must pin and recheck the selected implementation revisions before the first live run:

- Core `3ea5fb27fdfb001efbecc7ccc666845550ad7c43`: `spec/01-substrates.md`, `spec/06-identity.md`, `spec/07-verifier.md`, `CHARTER.md`.
- Kernel `352b0e0d79eba23b1883f83a2a654fc19d6699c2`: resource replay, signed admission HTTP, CAS, Badge Kind and export.
- Enterprise `28b4c4444abffa47873872c13597cc1a27b9890f`: fold role signer; AgentSession, LlmCall and ToolCall Kinds; Responses proxy routes and upstream selection.

The scoped design decisions above resolve the architectural choices for planning. Live compatibility, process-termination behavior and canonical integration are test gates to execute during implementation; none is represented as a passed test here.

## Review refinements

The design now constrains the signer to inspectable spec bytes and runtime-generated short-lived envelope fields; isolated harness configuration is part of captured context; and boot generations, credential revocation and nonce lookup bound restart/acknowledgment uncertainty. Machine-readable findings are bound to reviewer-signed recommendations. These refinements preserve the existing choice of a companion ManagedRequest, conservative uncertain-session blocking and non-forced pushes without a remote compare-and-swap claim. Subscription authentication under isolated harness configuration is still a live compatibility gate, not a documented success.
