# R5E-213 credential construction and scope boundary

`R5eRecurse.Authority.task_creation/1`, `session_endorsement/1`, and
`deployment_badge/1` return candidate plans, not admission receipts. Each accepts
`subject_public_key` (raw Ed25519 public bytes), `not_before`, and `not_after`.
Task creation additionally takes `task_id` and `node_ref`; session credentials
require `role` and `task_ref`. An `operator_badge` event ref is preserved both as
`spec.parent` and in the issuing request's authority list. Core verifies that the
issuer actually holds an effective parent with issuance permission and covering
Kinds and term. A caller cannot use another subject's Badge as session authority.

The canonical scope spellings are:

- Task creation: `{"taskId": "reserved logical Task id", "node": "exact Node resource ref"}`.
- Session endorsement and deployment Badge: `{"task": "exact Task admission event ref"}`.

These values are strings, not nested `$ref` objects: core's free-form scope schema
does not resolve them. Policy must resolve and compare the actual Task and Node
facts. The runtime service is the Task-creation subject; the ephemeral session is
the later endorsement and Badge subject. Creation grants contain only Task.

Roles are `:producer`, `:reviewer`, `:delegated_decision`, and `:runtime_action`.
Selecting the delegated decision role explicitly adds Decision to both credential
Kind sets; it does not establish target/disposition authorization. Decision policy
and the operator's separately admitted decision delegation remain required.

`envelope/4` accepts an already built eight-field canonical Request and signer
handles `%{public_key: raw32, sign: callback}`. The callback receives exact DSSE PAE
and returns `{:ok, raw64_signature}`. Every returned signature is verified before
an envelope is returned. Badge signatures are issuer first and subject second.
The request must bind the plan's exact target (including null content name),
canonical spec hash and authority list. This helper neither owns keys nor submits
requests. SessionKeys can provide the subject callback; operator callbacks remain
outside runtime custody. Helper refusal has no runtime-key fallback.

## Enforcement limits

The inspected kernel `R5e.Authority.resolve_entry/7` and `issue_under/3` enforce
subjects, Kind intersection, term, revocation and issuance ancestry. They do not
enforce field-level scope. The built-in Endorsement schema explicitly says scope
narrowing is not a core rule. `scope_allows?/2` is a strict equality helper for
resolved admission facts, not an independent authority mechanism.

Recurse Task/SessionBinding scope checks belong in the deployed policy adapter.
Gateway and CAS traffic also need the managed signer/route to bind each act to the
validated session Task (R5E-215 and gateway integration). This unit does not claim
that core globally enforces free-form scope or that client preflight prevents
bypassing admission policy. Candidate plans report
`scope_enforcement: :requires_deployment_policy` to retain that boundary.

## Validation

`authority_test.exs` checks role separation, exact Kind paths, candidate scope and
parent preservation, and verified ordered signatures. `authority_kernel_test.exs`
feeds the helper's actual envelopes into the real kernel admission pipeline and
checks wrong-subject, expired/revoked and Kind-intersection denials, Task-creation
non-authority for LlmCall/Decision, and parent Badge visibility. Its intentionally
minimal domain Kind schemas isolate credential behavior; domain scope checks are
covered separately by `delegation_scope_test.exs` against the deployed adapter.
