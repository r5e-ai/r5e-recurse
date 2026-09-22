# Tasks: Recorded development loop

**Input**: Design documents from `specs/001-recorded-development-loop/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md, contracts/execution.md, contracts/session-admission.md, contracts/managed-push.md, contracts/read-api.md  
**Generated**: 2026-09-21 by the designated reviewer role after the scope/design review. This file is a work breakdown, not a completion log; progress and review status live in Linear.

**Tests**: The specification and contracts name fixtures and negative tests explicitly (FR-010 marker fixture, contract "Tests" sections, plan regression list, quickstart "Review-derived negative cases"). Test tasks are therefore included and sit beside their implementation inside the same sub-header.

**Organization**: Phase 1 is plan slices A1 and A2; Phase 2 is slice B1; Phases 3 to 8 map one user story each in spec priority order (US1 = B2, US2 = B3, US3 and US4 = C, US5 = P, US6 = D); Phase 9 is slice E plus cross-cutting acceptance. Every `###` sub-header is one cohesive unit of work that one engineer closes with one merge request; the Linear sync collapses each sub-header into one issue.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel with its neighbours (different files, no dependency on an incomplete task)
- **[Story]**: US1 to US6 from spec.md; setup, foundational and polish tasks carry no story label
- Paths are relative to the `r5e-recurse` repository root

## Path Conventions

The repository is currently documentation only (no `mix.exs`, `lib/` or `test/`). The layout below follows the plan's proposed source layout with these additions: `test/support/` for shared test helpers, `test/live/` for tagged live-subscription tests, `priv/live/` for credential-free live-probe configuration, `priv/launcher/` for the POSIX process-group helper, and `tools/` for the non-Elixir independent readers required by read-api.md.

```text
lib/r5e_recurse/              application, lifecycle, commands, reconcile, kernel_client, context, review, reflection, lesson, session_keys, authority, signer, ...
lib/r5e_recurse/execution/    adapter, supervisor, local_cli, spool, harness, claude_code, codex
lib/r5e_recurse/actions/      git_push and its bare-repo dispatcher
lib/r5e_recurse/read/         index, router, controllers, content, auth
lib/mix/tasks/                recurse.* control, inspector, bootstrap, export
priv/kinds/                   recurse.r5e.io/v1alpha1 KindDefinition JSON (kernel priv/kinds shape)
priv/policy/                  Cedar policy sources and bundle manifest
priv/live/                    credential-free live-probe configuration and runbook
test/contract/  test/execution/  test/integration/  test/read/  test/live/  test/fixtures/  test/support/
tools/independent_reader/  tools/http_contract/
```

Operational guardrails that every task inherits: never run anything against the kernel's genesis development chain; every test kernel is an isolated chain started in the test environment. No private key, upstream bearer, channel secret or route credential is ever written to a file under `test/live/evidence/`, a manifest, an error message, a cursor or a log line.

---

> **Compression (2026-09-21, operator decision):** work is dispatched and reviewed by *phase milestone* (nine chunks; Phases 1–3 are the first deliverable). Phase 8 collapsed 5→2 units; 9.1 deferred to milestone two. 36 active units.

## Phase 1: Setup (slices A1 and A2)

**Purpose**: Establish the two real subscription paths through the gateway (A1, independent of runtime code) and the extension vocabulary, canonical client, command identity and pure reducers (A2) that every later phase builds on.

### 1.1 Scaffold the `:r5e_recurse` OTP application and pin the toolchain

- [ ] T001 Create `mix.exs` for `:r5e_recurse` (Elixir `~> 1.19`, OTP 28) with `jason`, `plug` and `bandit` dependencies, `lib/r5e_recurse/application.ex` with an empty supervision tree, `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs` and `test/test_helper.exs`; lock versions in `mix.lock`
- [ ] T002 [P] Pin the exact toolchain in `.tool-versions` and record the pinned Elixir/OTP versions in the README status section
- [ ] T003 [P] Add `.formatter.exs` and `.gitlab-ci.yml` running `mix format --check-formatted`, `mix compile --warnings-as-errors` and `mix test --exclude live --exclude perf`
- [ ] T004 Add `test/support/isolated_kernel.ex` (starts an isolated kernel chain in the test environment only, never the genesis chain) and `test/support/live_case.ex` (`@moduletag :live`, skips unless `R5E_LIVE=1`), registered via `elixirc_paths` in `mix.exs`

### 1.2 [A1] Provision the isolated kernel/gateway test deployment with explicitly selected upstreams

- [ ] T005 Write `priv/live/README.md`: designated test chain and gateway, explicit ChatGPT upstream for `/backend-api/codex/responses` and explicit Claude upstream, pinned core/kernel/enterprise revisions (research.md baseline, rechecked), and the rule that the gateway's shipped loopback Anthropic fallback is not a ChatGPT configuration
- [ ] T006 Add `priv/live/gateway-upstreams.json` (non-secret effective upstream selection snapshot for the test deployment) and `priv/live/check_endpoints.sh` that confirms, without credentials, which upstream each route selects and exits nonzero when the Codex route resolves to the Anthropic fallback
- [ ] T007 Add `test/live/endpoint_selection_test.exs` asserting the selected upstream per route from the gateway's non-secret status and refusing to continue when the ChatGPT upstream is absent

### 1.3 [A1] Codex subscription probe through the gateway under isolated configuration

- [ ] T008 Create `priv/live/codex/config.toml` (per-invocation custom provider using Responses, `requires_openai_auth = true`, gateway base URL, tools and integrations disabled) and `priv/live/codex/probe.sh` running a tiny no-tool prompt with an isolated `CODEX_HOME` and minimal auth-only provisioning (no copied home tree)
- [ ] T009 Add `test/live/codex_subscription_probe_test.exs`: real round trip; correlate incoming path, selected upstream, admission receipt and actual response; write credential-safe effective settings and canonical refs to `test/live/evidence/codex-probe.json`; assert no bearer appears in evidence
- [ ] T010 Exercise credential refresh and record its outcome (or an explicit `unverified` marker) plus the pinned Codex version in `test/live/evidence/codex-probe.json`; if the path is blocked, record the precise blocker in `priv/live/README.md` (test adapters stay labelled, milestone not reduced)

### 1.4 [A1] Claude Code subscription probe through the gateway under isolated configuration

- [ ] T011 Create `priv/live/claude/settings.json` and `priv/live/claude/probe.sh` (gateway base URL, isolated `HOME`/config directory, hooks and plugins disabled, minimal auth-only provisioning) for a tiny no-tool prompt
- [ ] T012 Add `test/live/claude_subscription_probe_test.exs` with the same shape as T009, writing to `test/live/evidence/claude-probe.json`
- [ ] T013 Exercise credential refresh and record its outcome (or `unverified`) plus the pinned Claude Code version in `test/live/evidence/claude-probe.json`; record any blocker precisely in `priv/live/README.md`

### 1.5 [A2] Declare the `recurse.r5e.io/v1alpha1` Kinds, base policy bundle and chain bootstrap

- [ ] T014 Write KindDefinition JSON (kernel `priv/kinds/*.json` shape, kind-definition v3, epistemic-scope description per docs/extending.md) for resource Kinds in `priv/kinds/graph.json`, `priv/kinds/node.json`, `priv/kinds/task.json` (Task: `delegatedBy`, `delegationRef`, step enum, earlier-attempt and recovery/decision refs)
- [ ] T015 [P] Write event Kinds `priv/kinds/session-binding.json`, `priv/kinds/context-manifest.json`, `priv/kinds/artifact.json` (structured `repoAssociation`), `priv/kinds/lifecycle-event.json`, `priv/kinds/command.json`
- [ ] T016 [P] Write event Kinds `priv/kinds/review.json`, `priv/kinds/decision.json`, `priv/kinds/recovery-decision.json`, `priv/kinds/reconciliation-observation.json`, `priv/kinds/managed-request.json`, `priv/kinds/action-result.json`, `priv/kinds/lesson-withdrawal.json`
- [ ] T017 Add `test/contract/kinds_test.exs`: one valid and one invalid instance per Kind against the kernel schema validator; required `custody`, `profile` and `signerReachability` fields present on SessionBinding and ContextManifest; cyclic Node parent rejected by domain validation
- [ ] T018 Write `priv/policy/base.cedar`: require `custody: runtime-held`, `profile: cooperative-local`, `signerReachability: same-user-cooperative-limit` on SessionBinding and ContextManifest; deny a managed session key acting with empty authority; require Badge subject, AgentSession admission actor and SessionBinding signer to be the same key; require SessionBinding authority to cite both the deployment Badge and the orchestrator-to-session Endorsement
- [ ] T019 Add `priv/policy/bundle.json` (manifest of Cedar sources with digests) and `docs/policy.md` describing how the development chain loads the bundle (Recurse-owned `recurse.r5e.io/v1alpha1/PolicyBundle`, `requiresAuthority: true`, exact authorized Kind paths excluding itself; fixed Recurse → fold → kernel adapter and tracked Facts reads per plan.md; receipts wrap every path and boot checks active chain policy)
- [ ] T020 Add `lib/mix/tasks/recurse.bootstrap.ex` admitting Kind definitions in dependency order and then node Endorsement over the Recurse Kinds, operator Badge and Recurse policy bundle to the selected chain; a re-run reports `existing` and changes nothing
- [ ] T021 Add `test/contract/policy_base_test.exs`: allow and deny fixtures for every rule in T018, by direct kernel HTTP submission without the runtime, including malformed/missing-label error, empty-authority denial, subject-mismatch refusal, upstream-deny/extension-allow, absent adapter, moved generation, generation conflicts and raising evaluation; receipt wrappers on every path

### 1.6 [A2] Kernel client for signed admission, CAS and canonical reads

- [ ] T022 Implement `lib/r5e_recurse/kernel_client.ex`: submit a signed envelope, put/get CAS bytes with digest verification, read events from a sequence, read resource-at-admission, request export; typed results that distinguish `denied` (attributable receipt) from `transport_failure` and `outcome_unknown`
- [ ] T023 Add `test/integration/kernel_client_test.exs` against the isolated kernel: grant, denial receipt, CAS digest mismatch refused, and a loss-after-admission-response fixture (response dropped by a test proxy in `test/support/dropping_proxy.ex`) surfacing as `outcome_unknown`, never as denial or success

### 1.7 [A2] Command envelope, serialized dispatcher and command identity

- [ ] T024 Implement `lib/r5e_recurse/commands.ex`: envelope (`command_id`, `operation`, `origin`, `target`, `expected_state_ref`, canonical payload), caller-key-scoped command ID, canonical payload digest, results `accepted | denied | existing | conflict | outcome_unknown`; one serialized dispatcher GenServer with single-writer ownership acquisition that fails rather than relying on in-memory locks; operations `submit_task`, `start_session`, `cancel_session`, `record_decision`, `request_push`, `recover_attempt`, `select_lesson` registered as stubs
- [ ] T025 Implement `lib/r5e_recurse/commands/dedup.ex`: Command event admission and a deduplication index rebuilt from canonical Command events on boot
- [ ] T026 Implement `lib/r5e_recurse/commands/operator_signature.ex`: operator-signed control envelopes for decision-class commands via a configured operator key held outside the runtime through configured command argv plus fixed arguments, with the bounded root-key/1 Ed25519 helper protocol and local signature verification specified in contracts/session-admission.md (custody path documented in `docs/policy.md`); the runtime service key never substitutes for the operator; hardware compatibility requires evidence
- [ ] T027 Add `test/contract/commands_test.exs`: same ID and identical digest returns `existing` with the current result; same ID and different digest returns `conflict` with no dispatch; lost acknowledgment is resolved by command-ID lookup, not a fresh command; a protocol nonce replay is a recorded denial, not deduplication; a second runtime writer fails ownership acquisition

### 1.8 [A2] Pure lifecycle reducer and derived status

- [ ] T028 Implement `lib/r5e_recurse/lifecycle.ex`: attempt state machine (`preparing -> ready -> running -> reflecting -> completed | declined | failed`; `cancellation_requested -> cancelled` only after observed stop; `interrupted` and `outcome_unknown`), prior-lifecycle-event refs, execution-generation tagging, preparation failure recordable before any binding exists
- [ ] T029 Implement `lib/r5e_recurse/lifecycle/derived.ex`: artifact advancement (`produced -> review_pending -> reviewed -> accepted | revision_requested | declined | escalated`), reflection status (`pending | available | interrupted | unavailable_acknowledged`) and lesson eligibility, all derived from admitted records without mutating desired intent
- [ ] T030 Add `test/lifecycle_test.exs`: replay from canonical event fixtures in `test/fixtures/events/` reproduces state; illegal transitions rejected; `completed` requires the step's artifact and an actual reflection; an artifact awaiting review is never `accepted`; retry preserves Node and creates a new Task/session

**Checkpoint**: Both live probes have evidence or a precise blocker; Kinds and base policy are admitted on the isolated chain; commands, reducer and kernel client have contract fixtures.

---

## Phase 2: Foundational (slice B1: session identity)

**Purpose**: Runtime-held session keys under deployment Badges and operator delegation, the spec-bytes signer and its channel, lost-acknowledgment recovery and ManagedRequest validation. No user story can be demonstrated without these.

**CRITICAL**: No user story work can begin until this phase is complete (2.7 may remain blocked on the enterprise issue while story work proceeds against test adapters).

### 2.1 Ephemeral key custody, execution generations, boot revocation gate and signer channel

- [ ] T031 Implement `lib/r5e_recurse/session_keys.ex`: one Ed25519 key per session kept in-process only; boot ID plus run ID as execution generation; sign only for current-boot bindings; destroy the key at terminal closure; no file or raw-key CLI surface
- [ ] T032 Implement `lib/r5e_recurse/boot.ex`: on start close the ordinary mutation gate, reconcile interrupted bindings, admit issuer-authorized Revocation for every unconfirmed session Badge, open the gate only after success; expose a narrow observation/revocation path while closed
- [ ] T033 Implement `lib/r5e_recurse/signer/channel.ex`: operator-permissioned Unix socket with a gateway-held per-boot shared secret, route/credential/generation registration before launch, rotation on runtime or gateway restart, reauthentication of current-generation bindings; the secret never reaches a CLI or an artifact
- [ ] T034 Add `test/session_keys_test.exs` and `test/integration/boot_gate_test.exs`: pre-boot generation refused; key not recoverable from the log; revocation failure keeps the gate closed; a recorded SessionBinding does not revive a live route
- [ ] T035 Add `test/signer_channel_test.exs`: unauthenticated socket access refused; old channel secret refused after rotation; stale generation refused; a supplied session string or account header selects no signer; the live binding dies with the process

### 2.2 Operator delegation chain and deployment Badge issuance

- [ ] T036 Implement `lib/r5e_recurse/authority.ex`: Task-creation Endorsement from the operator to the runtime service key scoped to a reserved logical Task ID and Node; post-Task Endorsement from the operator to the session key scoped to that Task; deployment Badge to the session key (`subjectKind` `agent` or `service`, `mayIssue: false`, term, explicit `kinds`) with subject countersignature; when the operator acts under a Badge the Endorsement exercises it as `parent`
- [ ] T037 Implement `lib/r5e_recurse/authority/kinds.ex`: role to fully qualified Kind list (model session, reviewer adds Review, delegated decision maker adds Decision, runtime action session receives only span/binding/ToolCall/Artifact/CasObject); no brace lists or wildcards in credentials
- [ ] T038 Add `test/contract/authority_test.exs`: a Badge whose subject is another key cannot be cited directly as session authority; expired and revoked terms denied; widened role (Kind outside the intersection) denied; Task-creation grant confers no model or decision authority; the operator Badge remains visible through the resolved parent chain

### 2.3 AgentSession span and SessionBinding admission

- [ ] T039 Implement `lib/r5e_recurse/session_binding.ex`: admit the `gateway.r5e.io/v1alpha1/AgentSession` span under the session key citing Badge and Endorsement; admit the session-signed SessionBinding with Task ref, span ref plus its admission event, key ID, Badge and Endorsement refs, boot/run generation, role, actor type (`agent` or `runtime_action`), provider/model or harness/version, ContextManifest ref, workspace digest and the required custody/profile labels
- [ ] T040 Add `test/contract/session_binding_test.exs`: a copied session ID or credential presented for a different session denied; missing span admission event denied; `agent` binding without provider denied while `runtime_action` without provider allowed; missing labels denied by policy

### 2.4 Spec-bytes signer with negative tests

- [ ] T041 Implement `lib/r5e_recurse/signer.ex`: input `{kind, specBytes, authority}` on the authenticated channel; allowlisted fully qualified Kinds; duplicate-key-rejecting JSON parse; core canonical encoding and DSSE PAE; resolve and check span, `upstreamHost`, model and `requestBody` ref including linked Prompt/LlmCall records; compute `specAddress`; validate the exact authority set; generate nonce; `expires` at most five minutes or the credential term end, whichever is earlier; reject extra fields; the Review path requires a well-formed duplicate-key-free findings block and exact recommendation equality; return only the DSSE envelope
- [ ] T042 Add `test/signer_test.exs`: caller-supplied `specAddress`, nonce, `expires`, actor or origin rejected; spec fields mismatching the registered span/model/upstream/body rejected; empty authority rejected; wrong signature, Badge or delegation subject rejected; expired/revoked term rejected; replay rejected; widened role rejected; extra fields rejected; free-text Review refused; signer outage reported without a fallback signer; the resulting canonical request has exactly the eight core fields

### 2.5 Nonce journal and lost-acknowledgment recovery

- [ ] T043 Implement `lib/r5e_recurse/nonce_journal.ex`: durable journal of `(origin, actor, nonce) -> operationId`, candidate digest and envelope written before submission; no private keys or auth headers; restart recovers lookups but refuses new signatures or submissions for pre-boot bindings
- [ ] T044 Implement `lib/r5e_recurse/nonce_journal/scan.ex`: on lost acknowledgment scan canonical event payloads for the recorded actor/nonce, validate the matching candidate and outcome before any resubmission, remain uncertain when no match is found while the submission may be in flight, never mint a replacement nonce
- [ ] T045 Add `test/integration/lost_ack_test.exs`: admission accepted with acknowledgment dropped is recovered by nonce lookup; a recorded denial is recovered; no match while in flight stays uncertain; zero resubmissions in every case

### 2.6 ManagedRequest candidate validation and first-input equality

- [ ] T046 Implement `lib/r5e_recurse/managed_request.ex`: build the session-signed ManagedRequest candidate (SessionBinding, admitted LlmCall ref, exact inbound/outbound body bytes and digest, first-input field path and digest, method/path/upstream/transport, allowlisted semantic headers, operation ID); transformation-free check; for the session's first request, losslessly decode the JSON provider body and require the specified input string to equal the ContextManifest rendered bytes exactly
- [ ] T047 Add `test/managed_request_test.exs`: first-input mismatch refused; unidentifiable supplied segment refused; mutated outbound bytes refused; authentication headers absent from the record; later requests skip equality but record harness-added input with provenance

### 2.7 Enterprise gateway integration (depends on public r5e-enterprise issue #8; implemented in the enterprise repository)

The managed binding registry, authenticated signer bridge client, ManagedRequest admission before forwarding, nonce-lookup recovery on the gateway side and disabled automatic proxy/client retries on managed bindings are delivered in `r5e-enterprise` under public issue #8. This sub-header only pins the contract and integrates against that delivery; a runtime-only task cannot stand in for it. Test adapters permit development while #8 is open; the live gate in 3.5 stays unmet until it ships.

- [ ] T048 Write `docs/integration/gateway-signer-bridge.md`: message shapes for route registration, sign request/response and result observation on the signer channel, ManagedRequest ordering (both admissions before forward), `not_dispatched` semantics and the retry-off requirement; link r5e-enterprise issue #8 and mark the sub-header blocked until it ships
- [ ] T049 Add `test/integration/gateway_bridge_contract_test.exs` (`:live`) against the pinned enterprise revision: route registration, signing via the channel, ManagedRequest admitted before forward with the session key as actor (no fold-only substitute), LlmCall without ManagedRequest read as `not_dispatched`, upstream accepted then dropped response with actual client retries producing zero second dispatch, `outcome_unknown` blocking further forwarding on the binding
- [ ] T050 Record the pinned enterprise revision and the status of issue #8 in `priv/live/README.md`

**Checkpoint**: Two distinct session keys with Badges, admitted spans and SessionBindings on the isolated chain; signer negatives pass; lost-ack recovery passes; the bridge contract is pinned.

---

## Phase 3: User Story 1 - Delegate a bounded task and inspect its record (Priority: P1) - MVP

**Goal**: The operator submits a bounded task with explicit context and acceptance criteria, a supported CLI runs under a managed session through the gateway, and the operator retrieves supplied context, session credential, output artifact and terminal result, distinguishing captured from unobserved.

**Independent Test**: Run one bounded task separately with Claude Code and with Codex; retrieve supplied context, session credential, output and terminal result without consulting private agent memory (spec US1).

### 3.1 Adapter behaviour, fake adapter and execution supervisor

- [ ] T051 [US1] Define `lib/r5e_recurse/execution/adapter.ex` behaviour: `capabilities/0`, `prepare/1`, `start/1`, `observe/1`, `cancel/2`, `reconcile/1` with typed structs (capabilities declare harness version, auth/transport modes, cancellation and descendant guarantees, tool restrictions, evidence limits); adapters receive a session-scoped route credential, never the signing key
- [ ] T052 [P] [US1] Add `test/support/fake_adapter.ex`: scriptable adapter for fault injection (exit codes, output patterns, hangs, missing executable, refusal to reconcile)
- [ ] T053 [US1] Implement `lib/r5e_recurse/execution/supervisor.ex`: DynamicSupervisor with temporary workers, explicit owner monitoring, independent idle (5 min default) and hard (30 min default, per-task override recorded in launch context) timers with retained handles, generation-tagged timer messages, stale generations ignored, no automatic restart of execution workers
- [ ] T054 [US1] Add `test/execution/supervisor_test.exs`: stale timer delivery ignored; hard deadline fires despite continuous output; idle limit fires independently; caller death stops the worker; supervisor restart relaunches no work

### 3.2 Process launcher with process-group ownership and framed output capture

- [ ] T055 [US1] Implement `lib/r5e_recurse/execution/local_cli.ex` and `priv/launcher/r5e_launch.c` (small POSIX helper: new process group, exec of an argument vector, no shell): identifiable process group, ownership and generation information, group termination; validated on macOS before any descendant-cancellation claim
- [ ] T056 [US1] Implement `lib/r5e_recurse/execution/spool.ex`: separate stdout/stderr spools with bounded 8 MiB chunks and sequence numbers; bounded buffering of split JSON and UTF-8 frames; final result file read before temporary cleanup; 64 MiB total trace budget (request bodies counted) that stops the session with `capture_incomplete` rather than dropping bytes
- [ ] T057 [US1] Add `test/execution/local_cli_test.exs` with fixtures `test/fixtures/procs/missing_exe`, `valid_text_then_nonzero.sh`, `final_file_only.sh`, `stderr_noise.sh`, `split_json.sh`, `oversized_no_newline.sh`: none normalizes to success; original bytes preserved; parsed events cite chunk coverage; process group identity recorded

### 3.3 Context manifest, renderer and harness configuration inventory

- [ ] T058 [US1] Implement `lib/r5e_recurse/context.ex`: ordered parts with source event/version, content ref, provenance (`operator_instruction`, `policy`, `task_evidence`, `reviewed_lesson`) and required flag; reads from an explicit repository root and revision only; 512 KiB byte ceiling plus the selected model's token budget; omissions with source and reason; rendered input bytes to CAS; ContextManifest admitted under service authority with custody/profile/signerReachability labels
- [ ] T059 [US1] Implement `lib/r5e_recurse/context/harness_inventory.ex`: digest and origin of every effective non-secret harness config and instruction file, CLI overrides and sanitized-view mapping; credentials inventoried by reference only
- [ ] T060 [US1] Add `test/context_test.exs`: required missing or unsupported part fails preparation; over-budget refuses launch; optional omission recorded with reason; part hashes and rendered hash both verified; no ambient CWD or home source; no credential in any manifest field

### 3.4 Harness isolation, per-writer workspace and the marker-hook fixture

- [ ] T061 [US1] Implement `lib/r5e_recurse/execution/harness.ex`: isolated `HOME`/config directory per session, one writing directory per writer, minimal auth-only provisioning through each client's supported mechanism, suppression of project and global instruction files, hooks, plugins and integrations, capture of any mandatory configuration digest; refuse launch when suppression is unsupported
- [ ] T062 [US1] Add `test/fixtures/hostile_harness/`: a checkout carrying `CLAUDE.md`, `AGENTS.md`, `.claude/` hooks and `.codex/` configuration that write markers, plus an ambient `HOME` with marker-writing hooks and contaminating instructions
- [ ] T063 [US1] Add `test/execution/harness_isolation_test.exs`: fake-adapter run asserts environment and configuration; `:live` run of the real pinned Claude Code and Codex with isolation asserts no marker file, no inherited instruction in the effective input and that subscription authentication still succeeds

### 3.5 Claude Code and Codex adapters

- [ ] T064 [US1] Implement `lib/r5e_recurse/execution/claude_code.ex`: argument vector (no shell), stream event parsing, OS exit separated from model completion, first-input segment identification by field path for the ManagedRequest equality check, route credential injection, `cancel/2` and `reconcile/1`
- [ ] T065 [P] [US1] Implement `lib/r5e_recurse/execution/codex.ex`: per-invocation configuration, Responses event parsing, same contract as T064
- [ ] T066 [US1] Add `test/execution/claude_code_test.exs` and `test/execution/codex_test.exs` with recorded fixture streams in `test/fixtures/streams/`, plus `:live` bounded no-tool sessions for each CLI through the signed managed path with retrievable session-bound admission evidence saved to `test/live/evidence/` (SC-001)

### 3.6 Task submission, launch pipeline, artifact capture and control CLI

- [ ] T067 [US1] Implement `lib/r5e_recurse/launch.ex` behind `submit_task` and `start_session`: admit Graph/Node/Task (`delegatedBy`, `delegationRef`), prepare (context, key, Badge, Endorsement, span, SessionBinding), admit the launch-intent LifecycleEvent, enable routing, start; preparation failures recorded against the Task before any binding
- [ ] T068 [US1] Implement `lib/r5e_recurse/artifacts.ex`: `work` and `trace` Artifact admission with ordered chunk manifest, completeness, producing SessionBinding and structured `repoAssociation`; attempt enters `reflecting` with reflection pending after execution ends
- [ ] T069 [US1] Add `test/integration/launch_pipeline_test.exs`: Task, ContextManifest, Badge, SessionBinding and launch intent are admitted before start; expired or revoked credential yields no upstream act and a retrievable refusal; error exit never becomes `completed`; artifact admission failure yields `capture_incomplete`; artifact, trace and outcome are distinguishable in the record
- [ ] T070 [US1] Implement `lib/mix/tasks/recurse.ex`: `mix recurse.task submit --node --context --criteria`, `mix recurse.session status <id>`, `mix recurse.task show <id>` printing canonical refs, supplied context, session credential summary (public key ID, Badge ref), output artifact ref, terminal result and explicit unobserved/omitted items
- [ ] T071 [US1] Add `test/mix/recurse_task_test.exs` and write the exact runnable commands into `specs/001-recorded-development-loop/quickstart.md` section 2

**Checkpoint**: US1 independently demonstrable with both CLIs (live) and with the fake adapter (CI).

---

## Phase 4: User Story 2 - Recover or stop work without silently running it twice (Priority: P1)

**Goal**: Cancellation records request and observed termination separately; a crash after artifact creation preserves the artifact, marks the attempt interrupted and starts no replacement execution; retry requires a recorded RecoveryDecision citing a newer observation.

**Independent Test**: A controlled task produces an artifact and waits; cancel one run, crash orchestration during another; observe the managed process and the durable record (spec US2).

### 4.1 Cancellation with observed termination

- [ ] T072 [US2] Implement `cancel_session` in `lib/r5e_recurse/commands.ex` and `lib/r5e_recurse/execution/cancel.ex`: record `cancellation_requested`; graceful stop (5 s) then escalation with a 5 s observation window via the process group; record observed termination and stopped output, or `unconfirmed` with the limitation
- [ ] T073 [US2] Add `test/fixtures/procs/heartbeat_tree.sh` (child and grandchild emitting heartbeats) and a deliberately detached-descendant variant
- [ ] T074 [US2] Add `test/execution/cancel_test.exs`: both descendants exit and output stops; detached descendant yields `unconfirmed` with the cooperative-profile limitation surfaced; request and observation are separate events; a PID lookup alone never yields `cancelled`

### 4.2 Attempt reconciliation after restart

- [ ] T075 [US2] Implement `lib/r5e_recurse/reconcile.ex` and `recover_attempt`: on boot every unfinished attempt enters reconciliation; `adapter.reconcile/1` reports live/stopped/unknown ownership; ReconciliationObservation admitted under the runtime observer; orphan setup records (Badge or span without binding) retired without launch; recoverable spool bytes admitted with honest timing; no execution starts
- [ ] T076 [US2] Add `test/integration/crash_recovery_test.exs`: crash after artifact before reflection leaves the artifact retrievable, the attempt `interrupted`, zero replacement CLI processes and no fabricated reflection; crash with admitted binding and a live unconfirmed process is observed, stopped or marked unknown; admission loss and lost dispatch acknowledgment exercised as separate crash windows

### 4.3 RecoveryDecision and authorized retry

- [ ] T077 [US2] Write `priv/policy/recovery.cedar` and implement `lib/r5e_recurse/recovery_decision.ex`: dispositions `reconcile_only`, `finalize_incomplete`, `retry`; operator signature required; `observationRef` must be newer in canonical sequence than the interruption; `retry` creates a new Task and AgentSession under the same Node citing the earlier attempt and the decision
- [ ] T078 [US2] Add `test/contract/recovery_decision_test.exs`: retry without a newer observation denied; retry never marks the old attempt successful; `finalize_incomplete` leaves reflection `interrupted` or `unavailable_acknowledged`; the new Task cites the previous attempt; write quickstart.md section 6 commands

**Checkpoint**: SC-004 demonstrable: cancellation and crash-after-artifact with zero unapproved replacement executions.

---

## Phase 5: User Story 3 - Obtain independent review and decide what advances (Priority: P1)

**Goal**: A fresh session on the other provider reviews the exact artifact against explicit criteria with machine-readable findings; the operator or a recorded decision delegate records a separate Decision; a changed artifact requires a new review.

**Independent Test**: Give a fresh reviewer an immutable fixture artifact and criteria; demonstrate an accepted artifact and one requiring revision or refusal (spec US3).

### 5.1 Reviewer session assembly with a read-only sanitized view

- [ ] T079 [US3] Implement `lib/r5e_recurse/review.ex`: fresh session on the other provider with a new key and Badge; review ContextManifest assembled from the immutable target Artifact, criteria, policy and explicitly selected overlap only; read-only materialization excluding `CLAUDE.md`, `AGENTS.md`, `.claude/` and `.codex/` with exclusions recorded and original artifact bytes untouched
- [ ] T080 [US3] Add `test/review_context_test.exs`: producer conversation absent from the manifest; producer and reviewer provider, key and session differ; the hostile-harness fixture placed in the reviewed checkout produces no marker under the real pinned reviewer (`:live`); a reviewer lacking task evidence may record `decline` or `escalate`

### 5.2 Machine-readable findings and reviewer-signed Review

- [ ] T081 [US3] Implement `lib/r5e_recurse/review/findings.ex`: findings artifact schema with a `recommendation` field (`accept`, `revise`, `decline`, `escalate`), duplicate-key-free; `review_findings` Artifact admission; Review event signed through the signer's Review path
- [ ] T082 [US3] Write `priv/policy/review.cedar`: Review `recommendation` equals the parsed findings field; reviewer binding differs from producer binding in key, provider and session; target is an exact Artifact event, never a mutable name
- [ ] T083 [US3] Add `test/contract/review_test.exs`: findings `revise` with Review `accept` denied; same-provider reviewer denied; mutable target denied; missing reviewer reads as incomplete coverage, not a recommendation

### 5.3 Decision, decision delegation and re-review of changed artifacts

- [ ] T084 [US3] Implement `record_decision` and `lib/r5e_recurse/decision.ex`: disposition, exact target Artifact and Review events, rationale bytes ref; decision actor taken from the envelope
- [ ] T085 [US3] Write `priv/policy/decision.cedar`: operator-role key, or an effective operator-issued Endorsement scoped to `recurse.r5e.io/v1alpha1/Decision`, exact task/target, allowed dispositions and term whose Badge and task delegation also include Decision; runtime service key denied; a new Artifact version requires a new Review before any Decision; escalation beyond delegated scope recorded rather than accepted
- [ ] T086 [US3] Add `test/contract/decision_test.exs`: delegated accept within scope allowed; disposition outside scope denied; expired or revoked delegation denied; runtime key denied; new version without new review denied; operator override and decline recorded with recommendation and decision kept distinct; write quickstart.md section 3 review and decision commands

**Checkpoint**: Accept, revise, decline and escalate fixtures pass; delegated and operator decisions both recorded; changed version re-reviewed.

---

## Phase 6: User Story 4 - Learn from reviewed experience (Priority: P1)

**Goal**: Every session reflects before normal closure or its absence is recorded honestly; a lesson is a versioned artifact with cross-provider review and recorded acceptance; a later task cites the exact accepted version and records an evaluation.

**Independent Test**: From a recorded task and reflection, have the other provider review a proposed lesson, obtain the operator's acceptance of that version and supply it to a later task with explicit evaluation criteria (spec US4).

### 6.1 Reflection step and honest incomplete reflection

- [ ] T087 [US4] Implement `lib/r5e_recurse/reflection.ex`: reflect step before closure for `produce`, `review` and `evaluate` sessions producing a `reflection` Artifact by the same session; a `reflect` Task satisfies its own reflection without recursion; `interrupted` and `pending` states; operator acknowledgment closes an attempt as incomplete with `unavailable_acknowledged`; retrospective reflection by a new session is labelled and linked, never attributed to the original agent
- [ ] T088 [US4] Add `test/reflection_test.exs`: `completed` requires reflection; system-generated status text is never recorded as agent reflection; a crashed agent yields `interrupted`; retrospective reflection is linked and labelled; write quickstart.md section 3 reflection commands

### 6.2 Lesson artifacts, review, acceptance and withdrawal

- [ ] T089 [US4] Implement `lib/r5e_recurse/lesson.ex`: `lesson` Artifact versions with source reflection link and producing session/provider; `lesson_review` Task on the other provider; acceptance via Decision by the operator or the recorded decision delegate; eligibility derivation; LessonWithdrawal with optional replacement needing its own review and acceptance
- [ ] T090 [US4] Implement `select_lesson` in `lib/r5e_recurse/commands.ex`: selects only an eligible exact version; unaccepted, superseded or withdrawn versions are never selected implicitly
- [ ] T091 [US4] Add `test/lesson_test.exs`: eligibility requires cross-provider Review plus accepting Decision on the exact version; a changed lesson invalidates eligibility; withdrawal blocks future selection while preserving prior use; the producing provider drives reviewer provider selection

### 6.3 Supplying an accepted lesson and recording its evaluation

- [ ] T092 [US4] Extend `lib/r5e_recurse/context.ex` with `reviewed_lesson` parts citing the exact lesson Artifact event, and implement the `evaluate` step: explicit criteria in the Task, an `evaluation` Artifact (positive, negative or inconclusive) linked to the lesson version and the later task
- [ ] T093 [US4] Add `test/integration/lesson_loop_test.exs`: end-to-end fixture from reflection to evaluation with a negative outcome preserved; `:live` run recording SC-003 evidence refs to `test/live/evidence/`; write quickstart.md section 4 commands

**Checkpoint**: SC-003 demonstrable: one reviewed, accepted lesson supplied by exact version with a recorded evaluation.

---

## Phase 7: User Story 5 - Govern a managed push (Priority: P1)

**Goal**: Pushes go through a structured `git.push` ToolCall admitted before dispatch, from a runtime-owned bare repository with a distinct deploy key; protected refs are refused with no remote change; a lost response never causes an automatic second push.

**Independent Test**: Using a disposable repository and remote, admit one allowed branch push and refuse a protected-ref push; inspect both the chain and the remote refs (spec US5).

### 7.1 Push proposal, runtime action session and destination policy

- [ ] T094 [US5] Implement `request_push` and `lib/r5e_recurse/actions/git_push.ex`: configured repository registry (`repoId` to allowed remote URL, protected branches, deploy-key public identifier) in `config/runtime.exs`; resolve any moving local name to an exact OID and `objectFormat` before admission; `expectedRemoteRevision`; create a runtime action session (`runtime-git` harness, `subjectKind: service`, minimal Kinds) bound to `artifactRef` and `decisionRef`; admit `gateway.r5e.io/v1alpha1/ToolCall` with `tool: git.push` and structured `args`
- [ ] T095 [US5] Write `priv/policy/push.cedar`: `args.revision == Artifact.repoAssociation.oid` with matching `repoId` and `objectFormat`; accepting Decision resolves to that exact Artifact version; destination in the configured allowlist; reject `main` and other protected branches, tags, deletion, force, wildcard or multi-ref pushes, arbitrary URLs and missing artifact/decision evidence; a closed producer route or expired producer credential is never revived
- [ ] T096 [US5] Add `test/contract/push_policy_test.exs`: each rejection above; pushed OID differing from the accepted Artifact denied; refused request produces a canonical denial and no dispatch

### 7.2 Push dispatch from a runtime-owned bare repository

- [ ] T097 [US5] Implement `lib/r5e_recurse/actions/git_push/bare_repo.ex`: per-operation lock; fetch the exact admitted OID from the workspace into the bare repository over local transport with the expected upload-pack forced, hooks, recursive submodule fetches and unexpected protocols prohibited; verify object type and OID; runtime-controlled bare-repo configuration (no hooks, fsmonitor, credential helpers, URL rewrites, submodule recursion, checkout or filters); explicitly constructed environment with `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` and cleared `GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_SSH_COMMAND`; deploy key injected after sanitization; effective remote asserted against the configured identity; recheck expected remote state; dispatch argument vector `<oid>:refs/heads/<branch>` non-forced single-ref; ActionResult with exit status, bounded stdout/stderr refs and observed remote OID
- [ ] T098 [US5] Implement `lib/r5e_recurse/actions/git_push/workspace.ex`: writer workspaces receive a dead local `pushurl` and no credential helper; the isolated harness environment never inherits the runtime push credential
- [ ] T099 [US5] Add `test/fixtures/hostile_git/` (hooks, fsmonitor, `core.sshCommand`, credential helper, URL rewrite and environment injection that write markers) and `test/integration/git_push_test.exs` against a disposable bare remote created in a temporary directory: allowed branch succeeds; `main` refused with unchanged refs; local branch moved after admission still pushes the admitted OID; wrong alias or URL rewrite refused; invalid OID refused; already-moved remote yields a non-fast-forward failed result; force, deletion and multi-ref rejected; no marker created by import or push; deploy-key identity used; no public remote ever contacted

### 7.3 Push recovery and lost-response reconciliation

- [ ] T100 [US5] Extend `lib/r5e_recurse/reconcile.ex`: crash after ToolCall admission or a lost push response marks the action `outcome_unknown`; the remote is queried and a ReconciliationObservation records observed remote OID as current state, never as proof of which actor moved it; a RecoveryDecision is required before any repeat dispatch; duplicate `operationId` with different args returns `conflict`
- [ ] T101 [US5] Add `test/integration/git_push_recovery_test.exs`: successful push with dropped response produces zero automatic re-pushes; crash before dispatch reads as `not_dispatched`; SC-005 evidence refs saved; write quickstart.md section 5 commands

**Checkpoint**: SC-005 demonstrable: matching pre-act evidence and remote observations; refused push changes zero remote refs.

---

## Phase 8: User Story 6 - Inspect history through an independent client (Priority: P1)

**Goal**: A snapshot-labelled read index and loopback HTTP facade expose tasks, sessions, ordered events, artifacts, revisions, commands, evidence and snapshots with stable pagination; an inspector and a bundle-only non-Elixir reader reconstruct the same lineage; a coherent canonical bundle passes the reference verifier.

**Independent Test**: An independent reader reconstructs a completed task from the exported bundle alone, then compares canonical lineage with the documented facade response (spec US6).

### 8.1 Read index, loopback HTTP facade and read credentials

- [ ] T102 [US6] Implement `lib/r5e_recurse/read/index.ex`: rebuildable in-memory projection from canonical events; ReadSnapshot (`origin`, `through_seq`, `checkpoint_ref`, `indexed_through_seq`, `index_version`, capture and disclosure scope) fixed at first read; when the index lags choose and report the older fully indexed checkpoint; retryable coverage error when none exists; snapshot metadata retained at least 24 hours; a rebuild serves an existing snapshot only when it reproduces version and coverage; orphan LlmCall labelled `not_dispatched` within the managed profile; custody/profile derived from source records; `source_event_refs` on every derived object
- [ ] T103 [US6] Add `test/read/index_test.exs` and a 10,000-event fixture generator in `test/support/event_fixture.ex`: rebuild after index loss reproduces coverage; a deliberately omitted edge is detected by rebuild diff; lag reporting; `:perf`-tagged p95 page build under one second excluding payload downloads


- [ ] T104 [US6] Implement `lib/r5e_recurse/read/router.ex` and `lib/r5e_recurse/read/controllers/{tasks,sessions,events,artifacts,revisions,commands,evidence,snapshots}.ex` on a configurable loopback port (not 4000): all nine endpoints of read-api.md; envelope `api_version`, `data`, `coverage`, `links`; opaque cursor binding origin, snapshot, endpoint/query/filter, last ordering key and index version; `limit` default 50 maximum 200 with limit+1 exhaustion; `400 invalid_cursor`, `410 snapshot_expired`, `409 outside_snapshot`; `payload_status`; error envelope with `retryable`; URL-encoded opaque IDs never split on slashes; no secret in any error or link
- [ ] T105 [US6] Implement `lib/r5e_recurse/read/content.ex` for `GET /v1/artifacts/{id}/content`: exact bytes with recorded media type and digest; `401/403` before `404`; `410` on recorded expiry; `503` on temporary source failure; never a modified original or a synthesized payload
- [ ] T106 [US6] Add `test/read/router_test.exs`: page boundaries, tied projection sort keys, new chain events excluded from an open snapshot, cursor filter mismatch, snapshot expiry, withheld payload, resource reference resolving to the captured admission version rather than the live replacement, unknown revision returning no match without implying no work


- [ ] T107 [US6] Implement `lib/r5e_recurse/read/auth.ex` and `lib/mix/tasks/recurse.read_credential.ex` (`issue`, `revoke`): server-side credential records mapping an opaque credential ID to one principal key and an explicit set of permitted command-owner keys/scopes; `GET /v1/commands/{id}` resolves `(ownerKey, commandId)` from that mapping with an optional owner selector restricted to the allowed set; credentials never emitted in evidence, links or cursors
- [ ] T108 [US6] Add `test/read/auth_test.exs`: identical command IDs owned by different keys resolve separately; revoked and expired credentials denied; forged owner selector denied; a decision Endorsement alone confers no read access; authorization precedes descriptive errors

### 8.2 Independent readers and coherent canonical export

- [ ] T109 [US6] Implement `lib/mix/tasks/recurse.inspect.ex`: follow a task through context, artifact, review, decision, reflection and lesson use via the facade, printing canonical refs and coverage for each hop
- [ ] T110 [P] [US6] Write `tools/independent_reader/` (Python 3, standard-library only; common exported canonical-byte fixtures with the Elixir client; reading/hash verification is not full signature verification): reconstruct task/review/lesson lineage from an exported canonical bundle with no facade calls, no database and no process memory; emit edges and source event refs; a `diff` mode compares with facade JSON at the same checkpoint and reports omitted or mislabeled edges
- [ ] T111 [P] [US6] Write `tools/http_contract/` (non-Elixir): HTTP contract test of read-api.md envelope, pagination, cursor errors, expiry and payload status against a running facade
- [ ] T112 [US6] Add `test/integration/two_reader_test.exs` orchestrating T109 to T111 against a fixture chain with an injected index omission and requiring the mismatch to be detected (SC-006, first half); write quickstart.md section 7 read commands


- [ ] T113 [US6] Implement `lib/r5e_recurse/export.ex` and `lib/mix/tasks/recurse.export.ex`: quiesce every writer to the selected chain (runtime mutation gate closed, gateway confirmed idle), capture one checkpoint, export the bundle through the kernel, verify unchanged head across export, run the reference verifier with explicit reader pins and `house` posture, retain the full verifier output and every not-checked limitation, refuse the `coherent` label otherwise; surface bundle metadata through `GET /v1/snapshots/{id}`
- [ ] T114 [US6] Add `test/integration/export_test.exs`: head change during export discards the candidate; quiescence not established refuses export; verifier limitations preserved unedited; the available bundle passes the verifier under the explicit settings (SC-006, second half)

**Checkpoint**: Facade reader and bundle-only reader agree at one checkpoint and detect an intentionally omitted edge; the bundle passes the verifier with limitations retained.

---

## Phase 9: Polish and cross-cutting concerns (slice E and acceptance)

**Purpose**: Optional disclosure selection, the end-to-end acceptance run that produces the evidence package, and the regression sweep that proves every named negative case has a test.

### 9.1 [E] Optional disclosure selection — DEFERRED to milestone two (not part of milestone-one acceptance)

- [ ] T115 Implement `lib/r5e_recurse/disclosure.ex`: an explicit disclosure Decision selects the public evidence subset; derived public bundle metadata identifies withheld payloads and their verification consequences; signed bytes are never edited; everything is private by default
- [ ] T116 Add `test/disclosure_test.exs`: nothing disclosed without a recorded disclosure decision; a subset is never labelled a full export; disclosed signed bytes are byte-identical to the originals; zero credentials or private payloads in the public subset (SC-007)

### 9.2 End-to-end acceptance run, evidence package and regression sweep

- [ ] T117 Run quickstart.md sections 1 to 7 on the development chain: one real non-fixture task whose artifact is later pushed (SC-002) with a second branch showing revise or decline and the operator's intervention, the lesson loop (SC-003), cancellation and crash recovery (SC-004), allowed and refused pushes (SC-005), two readers plus verifier (SC-006) and custody/profile checks (SC-007); store canonical references only (no payloads) in `specs/001-recorded-development-loop/evidence.md`
- [ ] T118 Finalize `specs/001-recorded-development-loop/quickstart.md` with the exact commands that were actually run per section, update the README status section, and write `docs/operating.md` covering per-task budget defaults and their recorded overrides
- [ ] T119 Add `test/regression/negative_cases_test.exs` mapping every item of quickstart.md "Review-derived negative cases" and the plan's regression list to an existing test module and failing when any item is unmapped
- [ ] T120 Add `test/regression/no_secret_leak_test.exs` scanning `test/live/evidence/`, manifests, error envelopes, cursors and captured logs for bearer, token, channel-secret and private-key patterns, and wire it into `.gitlab-ci.yml`
- [ ] T121 [P] Add a status note to `docs/architecture.md` aligning its Kind vocabulary with the admitted `recurse.r5e.io/v1alpha1` definitions without asserting any untested guarantee

---

## Dependencies and execution order

**Phase dependencies**

- **Phase 1 (Setup, A1 + A2)**: 1.1 first; 1.2 to 1.4 (A1) are independent of runtime code and run in parallel with 1.5 to 1.8 (A2). 1.3 and 1.4 depend on 1.2. 1.6 to 1.8 depend on 1.1 and 1.5.
- **Phase 2 (Foundational, B1)**: depends on Phase 1 A2 (1.5 to 1.8). 2.1 -> 2.2 -> 2.3 -> 2.4 -> 2.5 -> 2.6 is the internal order (2.4 needs 2.3 for registered span/binding resolution; 2.5 needs 2.4; 2.6 needs 2.4). 2.7 depends on 2.4 to 2.6 and on public r5e-enterprise issue #8; it may stay blocked while story phases proceed against the fake adapter.
- **Phase 3 (US1, B2)**: depends on Phase 2 (2.1 to 2.6). 3.1 and 3.2 in parallel; 3.3 and 3.4 in parallel after 3.1; 3.5 after 3.2 to 3.4; 3.6 after 3.5. Live SC-001 evidence in 3.5 additionally depends on 1.3, 1.4 and 2.7.
- **Phase 4 (US2, B3)**: depends on Phase 3 (3.1, 3.2, 3.6). 4.1 -> 4.2 -> 4.3.
- **Phase 5 (US3, C)**: depends on 3.3 to 3.6 and 2.2 to 2.4 (reviewer key, Badge, Review signing path). 5.1 -> 5.2 -> 5.3.
- **Phase 6 (US4, C)**: depends on Phase 5 (Decision path for lesson acceptance) and 4.2 (interrupted reflection). 6.1 -> 6.2 -> 6.3.
- **Phase 7 (US5, P)**: depends on 1.7, 2.2, 2.3, 4.2 (reconciliation) and 5.3 (accepting Decision). Can develop alongside Phase 6.
- **Phase 8 (US6, D)**: 8.1 and 8.2 may begin after Phase 1 A2 against fixture events; 8.3 after 1.7; 8.4 and 8.5 extend through Phases 3 to 7 and complete only after 7.3.
- **Phase 9**: 9.1 after 8.5; 9.2 after every other sub-header.

**Sub-header dependency graph**

```text
1.1 ─┬─> 1.5 ─┬─> 1.6 ─> 1.7 ─> 1.8
     │        └─> 8.1 ─> 8.2 ─> 8.3 (fixture-driven start; completes after 7.3)
     └─> 1.2 ─┬─> 1.3
              └─> 1.4
1.5, 1.6, 1.7, 1.8 ─> 2.1 ─> 2.2 ─> 2.3 ─> 2.4 ─> 2.5 ─> 2.6 ─> 2.7 [blocked on r5e-enterprise #8]
2.1..2.6 ─> 3.1 ─┬─> 3.3 ─┐
          ─> 3.2 ─┼─> 3.4 ─┼─> 3.5 ─> 3.6
                  └────────┘   (3.5 live gate also needs 1.3, 1.4, 2.7)
3.6 ─> 4.1 ─> 4.2 ─> 4.3
3.6, 2.4 ─> 5.1 ─> 5.2 ─> 5.3
5.3, 4.2 ─> 6.1 ─> 6.2 ─> 6.3
5.3, 4.2, 1.7 ─> 7.1 ─> 7.2 ─> 7.3
7.3, 6.3, 8.3 ─> 8.4 ─> 8.5 ─> 9.1 ─> 9.2
```

**User story completion order**

US1 -> US2 -> US3 -> US4; US5 in parallel with US4 once US3 and US2 are done; US6 index and facade started early against fixtures and finished last. All six stories are P1 and all are required for milestone one; no story is optional.

**Within each sub-header**

- Implementation and its tests land in the same merge request; the merge request is not complete while any named negative case in that sub-header lacks a test.
- Kinds and policy before reducers; reducers before commands; commands before adapters and endpoints.
- A `:live` test that cannot run records its precise blocker; it is never replaced by a passing fake and never deleted.

---

## Parallel opportunities

- Phase 1: 1.2 to 1.4 (A1, no runtime code) run alongside 1.5 to 1.8 (A2). T015 and T016 are parallel within 1.5.
- Phase 3: 3.1 and 3.2 in parallel; 3.3 and 3.4 in parallel; T064 and T065 (the two adapters) in parallel.
- Phase 6 and Phase 7 run in parallel once 5.3 and 4.2 are merged.
- Phase 8: 8.1 and 8.2 begin against fixture events as soon as 1.8 exists; T110 and T111 (non-Elixir readers) in parallel.
- 2.7 (enterprise integration) is tracked separately and does not block fake-adapter development of Phases 3 to 8.

**Parallel example: Phase 3 (US1)**

```text
Engineer A: 3.1 Adapter behaviour, fake adapter and execution supervisor
Engineer B: 3.2 Process launcher with process-group ownership and framed output capture
then
Engineer A: 3.3 Context manifest, renderer and harness configuration inventory
Engineer B: 3.4 Harness isolation, per-writer workspace and the marker-hook fixture
then
Engineer A: T064 Claude Code adapter    Engineer B: T065 Codex adapter
then one engineer: 3.6 Task submission, launch pipeline, artifact capture and control CLI
```

---

## Implementation strategy

**MVP first (US1)**

1. Phase 1: scaffold, both live probes (or precise blockers), Kinds, base policy, kernel client, commands, reducer.
2. Phase 2: session identity through 2.6; pin the enterprise bridge contract (2.7) and track issue #8.
3. Phase 3: US1 with the fake adapter in CI and both real CLIs live.
4. Stop and validate: the US1 independent test passes with both CLIs; SC-001 evidence refs exist.

**Incremental delivery**

1. Add US2 (recovery and cancellation) and validate SC-004.
2. Add US3 (review and decision), then US4 (reflection and lessons) and validate SC-003.
3. Add US5 (managed push) in parallel with US4 and validate SC-005.
4. Complete US6 (reads, two readers, coherent export) and validate SC-006.
5. Phase 9: optional disclosure, the end-to-end acceptance run for SC-002 and SC-007, and the regression sweep.

**Live gates that are never reduced**

Both subscription paths (1.3, 1.4), the marker-hook isolation run (3.4, 5.1), the signed managed path with both CLIs (3.5) and the enterprise bridge contract (2.7) are acceptance dependencies. A blocked live path permits contract and test-adapter development but does not reduce the milestone; the blocker is recorded, not hidden by selecting a mock.

---

## Notes

- Every task names the exact file it creates or changes; a task touching many files names the module directory and the test module that covers it.
- Tests marked `:live` need `R5E_LIVE=1`, the isolated development chain and gateway from 1.2, and never the genesis chain.
- Delivery status, review decisions and any re-scoping belong in Linear; this file is regenerated from the design documents and is not edited to record progress.
