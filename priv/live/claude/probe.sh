#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared credential-safe runner is delivered by R5E-206. The override permits
# exercising separate issue workspaces before those merge requests are merged.
runner="${R5E_LIVE_PROBE_RUNNER:-$script_dir/../run_probe.py}"
exec python3 "$runner" "$script_dir/profile.json"
