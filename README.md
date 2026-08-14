# r5e-recurse

> The recursive meta-harness — the r5e protocol's first real extension, and
> its first real user. `r5e` expands to *recurse*, so read the name as
> **recurse, applied to itself**: a fixed point, which is exactly what this is.

## What this is

[`r5e-core`](../r5e-core/) defines the protocol. [`r5e-kernel`](../r5e-kernel/)
implements it — the API server, substrates, and admission gate. **This
repository is the problem-solver built on top**: recursive decomposition,
governed agent sessions, independent review, mandatory reflection.

- Problems decompose into graphs of nodes; nodes produce tasks; tasks
  materialize agent sessions under explicit, monotonically narrowing
  authority.
- Sessions produce content-addressed artifacts with lineage; no artifact
  advances without independent review; every session reflects before it
  terminates, and reflections feed the next decomposition.

Refine, reflect, recurse. The protocol's name is this system's control flow.

Everything here lives in the `recurse.r5e.io/*` API groups and enters
through the same admission pipeline as anyone's extension. If the extension
mechanism can carry a full recursive orchestration system, it can carry your
lab procedure, your evidence schema, your legislature.

## What lives here

| Path | What it is |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Three planes, the Node → Task → Session → Artifact chain, the virtual substrate, legible mediation. |
| [docs/extending.md](docs/extending.md) | How this repo extends core — written as the template for third parties. |

Implementation is greenfield-pending on top of r5e-kernel; prior art being
consolidated and ported (not reconstructed): `rai_runtime` (decomposition,
GAN review, lifecycle state machines) and the orchestration layers of
`r5e-enterprise`.

## Status and license

Docs-first skeleton, 2026-07. License intent per ADR-0004: **AGPLv3**.
