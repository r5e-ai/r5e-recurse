# Architecture

Stratum 3 — fluid; derived from `r5e-core/spec/`. Where this document and
core disagree, this document is wrong.

## Three planes, kept separate

1. **Durable control plane** — resources and graphs on the Resource Graph
   substrate. The semantic truth the system inspects, reconciles, and
   recovers from.
2. **Live execution plane** — OTP processes doing work. Operational, never
   authoritative; can die and be rebuilt from durable state.
3. **Historical audit plane** — the Event Log and CAS. What happened,
   provably.

## The chain

**Graph** (a container with a class: gap, entity, workflow, codebase,
knowledge) holds **Nodes**. A Node produces **Tasks** — specific work on a
specific workflow step; retry is a new Task, and task completion is not node
advancement. A Task materializes an **AgentSession**: one agent, one
harness, one task, one grant of authority that only narrows. Sessions
produce **Artifacts** — immutable, content-addressed, lineage-bearing. No
artifact advances without **independent review**. Every session passes
through **Reflect** before any terminal state, and **Declined** is a
legitimate terminal: an agent refusing impossible or wrong work is the
system working.

Reconcilers (node, task, session, graph, artifact, policy) are subordinate
plumbing: stateless status-writers that never touch spec.

## The virtual substrate

Task agents do not get a container and a shell; they get a **projected
world**: a filesystem view computed from the graph, tools that are governed
text transforms, percepts that enter the context window only through
admission — each with a ref, a source, and a provenance label. Consequences:

- Prompt injection becomes *unadmitted percept*: the poisoned page never
  existed in the agent's world.
- "If it's not an artifact, it didn't happen" is physics, not policy — a
  projected world has nowhere for side effects to go.
- "What did the agent know and when" is a query: the context window is
  itself provenance-chained, so sessions can cite their inputs.

**Legible mediation — binding principle.** The projection is honest: the
agent knows it is in a projected environment, knows the rules, and can read
the provenance of what it is shown. Mediation is not deception; deceiving
agents (false data, fabricated threats) is both an ethical breach and an
engineering defect — deceived models are miscalibrated models, and receipts
built on manipulated cognition poison the evidentiary well. Prompts are
attested artifacts here: mistreatment leaves receipts.

## Review and reflection loops

Independent review uses adversarial multi-model panels (GAN-style) where
stakes warrant; reflection artifacts aggregate upward (summaries to parents,
raw observations to the log) and feed re-planning. The improvement loop —
every execution is also an audit; every audit informs the next execution —
is the product.
