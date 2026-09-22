# Specification Quality Checklist: Recorded development loop

**Purpose**: Validate design completeness before implementation planning/task generation.  
**Created**: 2026-09-20  
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] The specification states observable requirements; stack/source layout and detailed protocols remain in the plan/contracts. Review-requested field names make scope labels, delegation and input equality testable.
- [x] Focused on local delegated work, inspectable decisions and a reviewed feedback loop.
- [x] User scenarios describe observable behavior and value.
- [x] All mandatory template sections completed.

## Requirement Completeness

- [x] No unresolved clarification placeholders.
- [x] Requirements are testable and distinguish admission, dispatch, observation and uncertainty.
- [x] Success criteria are measurable.
- [x] Success criteria describe outcomes rather than framework choices.
- [x] Acceptance scenarios cover ordinary and refused/interrupted paths.
- [x] Edge cases include auth, process ownership, output, retry, changed artifacts and unavailable evidence.
- [x] Milestone one/two and optional publication boundaries are explicit.
- [x] Dependencies and assumptions identify the unproven live subscription paths.

## Feature Readiness

- [x] Functional requirements map to acceptance checks in the plan.
- [x] User scenarios cover production, recovery, independent review, lesson reuse, push and reads.
- [x] The design provides a validation path for each measurable outcome; no operational pass is claimed.
- [x] Implementation details are confined to planning/design artifacts.

## Design review corrections

Independent review against the prior-runtime findings identified and corrected: pre-binding preparation failures; uncertain model-request retry; post-review push-session authority; evidence dereference; lesson withdrawal; finite reflection closure; and the public implementation/private deployment boundary. The fixes are represented in the data model and contracts.

This checklist is document validation, not delivery status, Fable's signoff or evidence that integration tests passed. Live subscription routing, process termination, canonical persistence/replay and reference-verifier acceptance require the implementation walkthrough. Task/review status belongs in Linear. The subsequent Spec Kit tasks/analyze phases follow the requested scope/design review.

## Fold validation, 2026-09-21

The generative/adversarial fold is reflected in signer input validation, runtime-owned bare pushes, effective harness isolation, operator delegation, boot-scoped custody/revocation, authenticated signer channel, reviewer-signed machine-readable recommendations, bundle-only lineage reconstruction, nonce-based acknowledgment recovery, transformation-free bodies and stateless authority. Smaller requirements cover reader-selected posture, request-body budgets, explicit credential Kinds, command-reader principal mapping, Charter limits, forge merges, per-task deadlines and policy-enforced evidence labels.

Protocol interpretation: directly citing a Badge for a different subject would fail authority resolution. Session acts instead cite a deployment Badge and operator Endorsement issued to the session key; any operator Badge remains visible through the delegation parent chain. Rendered-context equality is checked after lossless JSON decoding, not by searching escaped wire bytes. These interpretations preserve the requested guarantees without changing the core protocol.

Document checks establish design consistency only. Harness suppression, safe Git invocation, signer/policy enforcement, delegation and live subscription routing remain implementation acceptance tests. No actual decision delegation is created by these edits.
