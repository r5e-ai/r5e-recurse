# Acceptance walkthrough

This is the intended acceptance procedure after implementation. The repository currently contains design artifacts; it does not yet supply a runnable runtime, these CLI operations or the new HTTP routes. Do not paste hypothetical commands and interpret their absence as a regression. The implementation must add exact tested setup commands to this file as each interface becomes runnable.

## 1. Establish the two real subscription paths

Use an isolated development chain and gateway, with explicitly selected upstreams for Claude and ChatGPT. Pin source revisions, model selection and both CLI versions. Confirm endpoint selection without credentials before sending an authenticated request; the gateway's shipped loopback fallback is not a ChatGPT configuration.

Configure Codex's custom provider using Responses and subscription authentication (`requires_openai_auth = true`) as described in the official [authentication guide](https://learn.chatgpt.com/docs/auth). Keep user authentication under the normal client, using per-invocation configuration for the test. Disable unneeded tools and external integrations for a tiny no-tool probe. Use supported Claude endpoint configuration for its equivalent probe. Save non-secret effective settings, incoming path, selected upstream, actual response and receipt linkage. Do not count an API-key or direct-provider result as the subscription gateway test.

Then test the session-signing integration: two distinct session keys/Badges, admitted gateway spans, SessionBindings and exact ManagedRequest bytes. Verify actor, authority and request/result linkage. Credential refresh behavior needs an explicit test outcome; login status alone does not establish it. If one client cannot complete the selected path, retain that narrow blocker; test adapters still permit development but the two-client milestone is not accepted.

## 2. Run a bounded development task

Choose a small change in a disposable working repository. Supply explicit acceptance criteria and context. Record task submission, context manifest, Badge, session binding and launch intent before execution. Use a unique writing directory and isolated home/configuration. Record all effective non-secret harness config digests and prove subscription auth still works without inheriting normal home/memory/hooks.

Retrieve the work artifact and exposed trace. Check raw-byte references, exact repository revision where applicable, non-secret invocation metadata and actual exit status. Confirm unknown/omitted input and output truncation are visible. The task must not become successful solely from text resembling success.

## 3. Review and reflect

Create a fresh reviewer session on the other provider, with a different key/Badge. Supply the immutable artifact, criteria and explicit overlap. Inspect the manifest to confirm the producer's private conversation was not inherited.

Record machine-readable findings and reviewer-signed Review with matching recommendation; prove mismatched findings/recommendation is refused. Establish the decision delegation by admitted Endorsement before exercising it, then record an authorized decision. Demonstrate a revise or decline path; a changed artifact needs a new review. Demonstrate the operator's intervention. Obtain an actual reflection artifact; interrupted reflection remains incomplete rather than a generated success summary.

## 4. Close the first learning loop

Produce a lesson artifact derived from reflection. Have the other provider review its exact version; the operator or its explicitly endorsed reviewer-session delegate accepts that version through a recorded decision. Start a later task whose input manifest cites that lesson and whose criteria define how its usefulness will be assessed. Record the later outcome, including negative or inconclusive evidence. This demonstrates an operational feedback loop, not universal self-improvement.

## 5. Exercise governed pushes

Use a disposable bare remote. Request a push to an allowed branch with exact repo identity, commit OID and ref. Verify ToolCall admission precedes the actual Git process and compare its arguments with the signed record. Record the result separately.

Request a protected-ref push and prove both a denial receipt and unchanged remote refs. Change local refs/destination configuration between proposal and dispatch to test exact binding. Simulate response loss after a successful push; recovery must not automatically repeat it or attribute a remote observation as proof of who pushed.

## 6. Prove cancellation and recovery

Run a harmless process fixture with a child/grandchild heartbeat. Cancel by session identity and verify observed process termination and stopped output, not only a changed status label. Exercise idle and hard limits independently.

In a separate attempt, admit a durable artifact and crash orchestration before normal completion/reflection. Restart. Confirm artifact retrieval, interrupted state, no replacement CLI process and no fabricated reflection. Record a recovery decision before a new Task/session is launched under the existing Node. Exercise admission loss and a lost dispatch acknowledgment as separate crash windows.

## 7. Read and verify independently

At a fixed checkpoint, use the facade inspector to follow both tasks through context, artifact, review, decision, reflection and lesson use. Independently reconstruct that lineage from exported canonical events/refs with no facade calls, then compare edges and source refs with the facade. Deliberately omit an index edge and require the comparison to detect it. Retain a separate non-Elixir HTTP client test for the read contract. Rebuild the read index and repeat. Exercise pagination with new events arriving, exact-page exhaustion, expired snapshots and withheld payloads.

Quiesce every writer to the test chain, export one coherent canonical bundle, confirm unchanged head across export, and run the reference verifier under explicit reader pins and `house` posture for this acceptance run; other readers choose their own pins and posture. Preserve all verifier limitations. If head changes or material is missing, report the limitation and do not call the candidate a coherent complete bundle.

## Acceptance evidence package

Store canonical references to:

- Source/client versions and credential-safe provider configuration.
- Both live subscription request/result chains and session Badge bindings.
- Producer, independent review, authorized decision, reflection, lesson review/operator acceptance and later evaluation.
- Allowed/refused push and remote observations.
- Cancellation, crash/recovery, process observations and zero unapproved replacement executions.
- Two-client read results, snapshot coverage, canonical bundle manifest and unedited verifier report.

Keep task/progress status in Linear. These files define the acceptance evidence; the actual test results should cite admitted evidence when the loop is operational. Public disclosure is a separate selected action, not an automatic consequence of completing this walkthrough.

## Review-derived negative cases

Before claiming acceptance, exercise: caller-supplied signer digest/nonce/expiry; empty managed authority; pre-boot signer generation and old channel secret; unconfirmed-session revocation failure; lost admission acknowledgment resolved by journaled nonce; orphan LlmCall read as managed `not_dispatched`; recovery retry lacking a newer observation; first rendered-input mismatch; hostile project/home hook with no resulting marker; agent-writable Git configuration with no executed marker; pushed OID differing from accepted artifact; and cross-owner command-ID reads. Request bodies count toward the per-task capture budget, and the default hard deadline can be overridden explicitly per task.
