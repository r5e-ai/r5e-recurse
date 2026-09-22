# Live subscription prerequisites

Phase 1 A1 uses a disposable gateway with its own PostgreSQL database,
kernel chain, node/fold signing keys and payload store. It never mounts the
genesis chain or a normal development gateway's storage. Provider credentials
are supplied by the clients only after the endpoint check passes.

## Source baseline

The public `main` revisions were rechecked on 2026-09-22 UTC:

| Repository | Revision |
| --- | --- |
| r5e-core | `3ea5fb27fdfb001efbecc7ccc666845550ad7c43` |
| r5e-kernel | `352b0e0d79eba23b1883f83a2a654fc19d6699c2` |
| r5e-enterprise | `28b4c4444abffa47873872c13597cc1a27b9890f` |

Build the enterprise release from those three source snapshots using its
`scripts/prepare-release.py` and `Dockerfile`. Keep the generated
`repos.lock.json` with the private deployment record and compare it to
`/app/etc/fold/repos.lock.json` in the image. An older cached gateway image is
not this baseline.

## Isolated deployment

Use the pinned enterprise `docker-compose.yaml` with a fresh project name
and no external volumes. The designated test project is
`r5e-recurse-a1-20260921`; its gateway is
`r5e-recurse-a1-20260921-gateway`. The audit and proxy listeners bind only
loopback, on host ports `15400` and `15443`. The container ports remain
`4000` and `4443`.

Keep the Compose overlay, generated database/session secrets and client auth
material outside this public repository. The overlay must select the freshly
built image, replace the base Compose `env_file` with the private file, disable
automatic restarts for the test, and set these non-secret values explicitly:

```text
R5E_GATEWAY_CONTAINER=r5e-recurse-a1-20260921-gateway
R5E_GATEWAY_PORT=15400
R5E_PROXY_PORT=15443
R5E_TENANT_ID=01TEN_RECURSE_A1
R5E_LIVE_TEST_ONLY=true
R5E_DEV_LOGIN_ENABLED=true
R5E_LLM_PROXY_UPSTREAMS=anthropic
R5E_LLM_PROXY_DEFAULT_UPSTREAM_HOST=none
R5E_LLM_PROXY_FALLBACK_UNKNOWN_HOSTS=false
LOGGER_LEVEL=info
```

Dev login is enabled only on this loopback test deployment, as in the pinned
Compose quickstart. The audit plane must stay enabled because it also starts
the active policy loader. No external identity provider is configured.

Retain the base Compose hardening, mandatory fold admission, isolated backend
network and separate named `pg_data`, `kernel`, `cas`, `secrets` and `policy`
volumes. Inspect mount names before first boot; none may refer to an existing
deployment. Do not dump resolved Compose configuration containing secrets.

The shipped `anthropic` preset seeds Claude's upstream. There is no ChatGPT
subscription preset; `openai_api` uses API billing and is not a substitute.
After boot, seed the subscription row once:

```sh
export R5E_LIVE_GATEWAY_CONTAINER=r5e-recurse-a1-20260921-gateway
docker exec "$R5E_LIVE_GATEWAY_CONTAINER" /app/bin/audit_console rpc \
  "$(cat priv/live/seed_upstreams.exs)"
bash priv/live/check_endpoints.sh
```

The seed requires the explicit test marker, test tenant and disabled fallback.
It does not overwrite an existing row. Check results before providing auth.

## Route selection gate

| Client | Inbound Host | Path | Selected upstream |
| --- | --- | --- | --- |
| Codex subscription | `chatgpt.com` | `/backend-api/codex/responses` | `https://chatgpt.com:443` |
| Claude subscription | `api.anthropic.com` | `/v1/messages` | `https://api.anthropic.com:443` |

**Selection is based on Host, not path.** A client using the loopback base URL
must send the listed Host. A bare localhost Codex URL with the shipped
Anthropic default could send a ChatGPT bearer to Anthropic. This deployment
disables both self-host defaults and unknown-host fallback; unconfigured
hosts must fail instead.

`check_endpoints.sh` uses Docker operator access to call the running release's
actual `ProxyRouter.select_upstream/2`. It needs no provider credentials. The
gateway currently has no HTTP upstream-status endpoint, so the script emits
an allowlisted JSON projection from release RPC; it does not read a checked-in
declaration as evidence of live configuration. Missing ChatGPT, wrong provider,
wrong auth/format, cleartext, disabled rows and fallback all fail the check.
Raw RPC output is withheld on failure.

`gateway-upstreams.json` is a dated, non-secret observation, not a substitute
for re-running the check. It proves selector configuration only. The subsequent
client probes must establish that the clients actually send the required Host
and path, and correlate admission, upstream response and final output. It does
not prove a successful subscription request, refresh, session-bound signatures,
tool admission or host containment.

## Verification

The endpoint tests can run before the application scaffold is merged:

```sh
elixir test/live/endpoint_selection_test.exs
R5E_LIVE=1 elixir test/live/endpoint_selection_test.exs
```

The second command also requires Docker and `R5E_LIVE_GATEWAY_CONTAINER`.
Fixtures test unsafe selections; the tagged live test always queries the
running gateway. A missing gateway fails that live test rather than passing
with the historical snapshot. Client probes and their refresh status are
tracked separately in R5E-206 and R5E-207.
