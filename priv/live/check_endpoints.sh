#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
container="${R5E_LIVE_GATEWAY_CONTAINER:?Set R5E_LIVE_GATEWAY_CONTAINER to the isolated test gateway}"
command -v docker >/dev/null || { echo 'endpoint check requires Docker' >&2; exit 2; }

# No provider token is needed. Release RPC uses operator access to the named
# container; it never prints the release cookie. Do not expose raw RPC errors:
# only the successful allowlisted status projection is emitted.
rpc="$(cat "$script_dir/endpoint_selection.exs" "$script_dir/endpoint_status.exs")"
if ! output="$(docker exec "$container" /app/bin/audit_console rpc "$rpc" 2>/dev/null)"; then
  echo 'endpoint check failed: gateway RPC unavailable or unsafe/missing upstream selection' >&2
  exit 1
fi
status="$(printf '%s\n' "$output" | sed -n 's/^R5E_UPSTREAM_STATUS=//p')"
if [[ -z "$status" || "$status" == *$'\n'* ]]; then
  echo 'endpoint check failed: no single validated upstream status returned' >&2
  exit 1
fi
printf '%s\n' "$status"
