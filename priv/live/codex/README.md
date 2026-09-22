# Codex subscription probe

This is the Phase 1 A1 transport prerequisite, not the later session-signing
acceptance test. It uses Codex **0.149.1**, the **ChatGPT subscription** auth
mode and HTTP/SSE to the explicitly configured `chatgpt.com` upstream. The
first recorded test returned HTTP 200 and correlated retained request and
response bytes with admitted Prompt, LlmCall, Completion and LlmResponse
records. Those admissions are signed by the gateway fold key.

The shared runner requires Python 3.9+, Docker, the endpoint checker from
R5E-205 and a client image with `/home/node` as its default user home. Build a
fresh image from `node:22-bookworm-slim`, install `ca-certificates` and
`@openai/codex@0.149.1` with npm, create an empty `/work` owned by `node`, and
select `USER node` and `WORKDIR /work`. No host configuration is mounted.
The paired test image may also include `@anthropic-ai/claude-code@2.1.223`.

Set these values for the isolated deployment described in `../README.md`:

```sh
export R5E_LIVE_GATEWAY_CONTAINER=r5e-recurse-a1-20260921-gateway
export R5E_LIVE_NETWORK=r5e-recurse-a1-20260921_egress
export R5E_LIVE_CLIENT_IMAGE=r5e/recurse-a1-clients:codex-0.149.1-claude-2.1.223
export R5E_LIVE_AUTH_FILE=/private/path/to/auth-only-codex.json
bash priv/live/codex/probe.sh
```

Provision only the existing CLI's auth cache through a private, owner-readable
file. The runner accepts `auth_mode: chatgpt` and its token object, discards
any API-key field, and checks the isolated CLI's selected login mode before
calling the model. OpenAI documents [auth-cache transfer to a
container](https://learn.chatgpt.com/docs/auth) and custom-provider
`requires_openai_auth`. The runner never changes the host's auth or settings.
It uses the new container's normal home rather than overriding host home
variables. A copied cache is still sensitive; keep it outside this repository.

`config.toml` disables integrations, instruction loading, compression, retries
and configurable tools. `models.json` contains the `gpt-5.5` entry from
[Codex rust-v0.149.1](https://github.com/openai/codex/blob/rust-v0.149.1/codex-rs/models-manager/models.json),
modified only to disable patch, search and experimental tool exposure. Its
source license is in `models-LICENSE`. In this version, disabling shell tools
alone does not remove patch or question tools. The retained request must have
an empty `tools` array; a no-tool prompt alone does not pass that check.

The runner uses a fresh container and marker for each explicit attempt. It
sets no automatic retries, limits the CLI invocation to 120 seconds, removes
the container afterward, and never prints raw CLI/RPC failures. A timeout is
`outcome_unknown`; inspect the chain before deciding whether to try again.
The container can reach external services for provider auth. This is home and
configuration isolation, not an all-traffic containment claim.

Evidence is written to ignored `test/live/evidence/codex-probe.json`, or
`R5E_PROBE_EVIDENCE_DIR`. It contains config digests, source pins, selected
route, exact canonical references and explicit refresh status. The collector
requires one matching prompt/call/response, verifies payload hashes and chain
integrity, checks the retained response marker and refuses advertised tools.
Known credential values and credential-shaped strings are rejected before
writing evidence. Raw transcripts, account identifiers and headers are absent.

The successful first pass did not observe credential refresh, so its status is
`unverified`. A changed access token during a future isolated run is recorded
as `observed_access_token_rotation`; it does not prove every refresh failure
mode. Refreshed credentials are not copied back into the host auth store.

Run `python3 test/live/probe_evidence_test.py` for credential-leak checks.
`R5E_LIVE=1 elixir test/live/codex_subscription_probe_test.exs` performs another
real probe and validates its evidence. Without `R5E_LIVE=1`, the live test is
excluded. The live test requires the same deployment/auth variables above.
