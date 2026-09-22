# Claude Code subscription probe

This Phase 1 A1 probe uses Claude Code **2.1.223**, Claude.ai subscription
credentials and the gateway's explicit `api.anthropic.com` upstream. It
requires the isolated deployment from R5E-205 and the shared credential-safe
runner/collector from R5E-206. It does not substitute an API key.

Build the client image as described in `../codex/README.md`, with
`@anthropic-ai/claude-code@2.1.223`. Select its default `node` user and empty
`/work` directory. Set the same gateway, network and image variables as the
Codex probe, then supply a private auth-only file containing `claudeAiOauth`:

```sh
export R5E_LIVE_AUTH_FILE=/private/path/to/auth-only-claude.json
bash priv/live/claude/probe.sh
```

On macOS, the normal CLI may keep this object in its Keychain entry; auth-only
provisioning is an operator action. Do not copy the home tree, settings,
plugins, MCP configuration, hooks or project history. Never put the auth-only
file in this repository. The runner verifies that the isolated CLI reports
`claude.ai` authentication before the model request.

The profile combines `--safe-mode`, empty setting sources, explicit
`settings.json`, an empty built-in tool list and empty strict MCP configuration.
In **2.1.223**, `--bare` disables OAuth reads, so it cannot replace this profile
for the subscription test. Anthropic documents
[CLI isolation flags](https://code.claude.com/docs/en/cli-reference) and
[base URL/custom headers](https://code.claude.com/docs/en/env-vars); the pinned
binary's help and the actual retained request establish what worked here.
The Host header explicitly selects Anthropic with gateway fallback disabled.

The first isolated attempt found expired auth and returned “OAuth session
expired and could not be refreshed” before a model request. After the operator
logged in again, fresh auth completed the real gateway round trip: HTTP 200,
zero advertised tools, expected output and matching admitted prompt, call,
completion and response records. Those records are fold-signed; they are not
Recurse per-session signatures. Successful in-container refresh remains
`unverified`; the expired-cache refresh failure is retained in the private
phase evidence. No host credential was overwritten by the probe.

Evidence is written to ignored `test/live/evidence/claude-probe.json`, or
`R5E_PROBE_EVIDENCE_DIR`, with the same schema and checks as Codex. A failed
attempt or uncertain response never becomes a passing mock. Run
`R5E_LIVE=1 elixir test/live/claude_subscription_probe_test.exs` with the
necessary deployment/auth variables to perform another real probe. It is
excluded when live execution is not requested.

Before the dependency MRs merge, `R5E_LIVE_PROBE_RUNNER` can name the shared
runner in its separate issue workspace and `R5E_LIVE_ENDPOINT_CHECK` can name
the R5E-205 checker. Point `R5E_PROBE_EVIDENCE_DIR` at this checkout's evidence
directory when exercising those separate workspaces.
