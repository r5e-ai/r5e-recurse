# Extending r5e — this repo as the template

Stratum 3 — fluid. r5e-recurse extends `r5e-core` exactly the way any third
party would; this document is deliberately written so you can substitute
your domain for ours.

## The steps

1. **Claim an API group.** Ours: `recurse.r5e.io/v1alpha1`. Yours:
   `provenance.your-domain.com/v1alpha1`.
2. **Define Kinds.** Each KindDefinition declares its substrate, schema, and
   — non-negotiably — its **epistemic scope**: what an attestation of this
   Kind claims and what it must not be read as claiming. Our `AgentSession`
   attests *which agent ran, under whose authority, seeing which admitted
   percepts*; it does not claim the agent's output is correct — that is what
   independent review Kinds are for. Write yours with the same candor.
3. **Declare answerable predicates.** The questions your evidence can prove
   answers to without disclosure. Ours include "did an independent reviewer
   approve this artifact?" A lab's might include "was the cold chain
   unbroken?" Predicates are your Kind's public interface to gates.
4. **Submit through admission.** A KindDefinition is an artifact like any
   other: authored, endorsed, reviewed, admitted, recorded. There is no
   registration portal because there is no back door; the front door is the
   product.
5. **Verify.** `recurse-verify` reads your receipts with no knowledge of
   your domain beyond the admitted KindDefinitions — that property, not our
   goodwill, is what makes your evidence third-party-checkable.

## The test of a good extension

Someone outside your organization, holding only your published
KindDefinitions and a receipt bundle, can answer: who acted, under whose
authority, on what, by what rule — and can state precisely what your
evidence does *not* establish. If the last part embarrasses you, the
extension is not done; the gap you are tempted to hide is the first thing
to instrument next.
