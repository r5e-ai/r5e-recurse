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

Implementation is starting on top of r5e-kernel, informed by prior art in `rai_runtime` (decomposition,
GAN review, lifecycle state machines) and the orchestration layers of
`r5e-enterprise`.

## Status and license

As of 2026-09-22, the OTP application scaffold compiles with an empty
supervision tree. Runtime orchestration remains under construction in
[R5E-208 through R5E-211](https://linear.app/r5e/issue/R5E-208).

| Toolchain | Pinned version |
| --- | --- |
| Elixir | 1.19.5 (OTP 28 build) |
| Erlang/OTP | 28.5 |

Run `mix deps.get`, then `MIX_ENV=test mix compile --warnings-as-errors` and
`MIX_ENV=test mix test --exclude live --exclude perf`. Container-backed kernel
tests opt in through `R5E_TEST_KERNEL_IMAGE`; they start fresh ephemeral chains
and never mount a development data directory. Real subscription tests require
`R5E_LIVE=1` separately.

License intent per ADR-0004: **AGPLv3**.
