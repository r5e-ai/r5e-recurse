# Operator command signer

Configure `R5eRecurse.Commands.OperatorSignature` with `command: [absolute_executable | fixed_arguments]`, a pinned 32-byte `public_key` and an optional bounded `timeout` in milliseconds (default 5000, maximum 120000). The helper owns the private key outside runtime custody. Never put private key bytes in command arguments, repository files or runtime configuration. There is no service-key fallback.

The helper receives a final `public-key` or `sign` argument. The first writes exactly one 32-byte Ed25519 public key as hex. The second reads one hex line containing exact DSSE PAE bytes and writes one 64-byte signature as hex. It must read a line, not await EOF. Human PIN or touch prompts use `/dev/tty`. Diagnostic stderr is discarded; helper failures return fixed safe errors. Output and elapsed time are bounded, and signatures are verified locally against the pinned operator key.

This implements a command custody boundary, not hardware integration. An existing PIV key must be confirmed Ed25519-compatible before hardware support is claimed. Tests use ephemeral compatible software keys in a separately invoked helper. No hardware ceremony or host secret is accessed.

The dispatcher accepts decision-class Command admissions only from its configured operator public keys. Reviewer-session delegation remains an explicit future authority-policy integration; runtime custody is never decision authority. The deployment must configure and enforce the Recurse policy in the admitting kernel as specified by the amended policy-hosting ruling.
