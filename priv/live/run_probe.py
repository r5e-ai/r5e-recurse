#!/usr/bin/env python3
"""Run one isolated subscription attempt; emit only allowlisted evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


def command(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, timeout=kwargs.pop('timeout', 30), **kwargs)


def collect(gateway, client, marker, root):
    # These values become Elixir literals, so accept only this generated alphabet.
    if client not in ('codex', 'claude') or not re.fullmatch(r'R5E_(CODEX|CLAUDE)_PROBE_[a-f0-9]{32}', marker):
        raise ValueError('invalid collection identity')
    code = (root / 'collect_probe.exs').read_text()
    code += '\ntry do\n IO.puts("R5E_PROBE_EVIDENCE=" <> Jason.encode!(collect_probe.('
    code += json.dumps(client) + ',' + json.dumps(marker) + ')))\nrescue _ -> IO.puts("R5E_PROBE_COLLECTION_FAILED")\nend\n'
    result = command(['docker', 'exec', gateway, '/app/bin/audit_console', 'rpc', code])
    lines = [line.removeprefix('R5E_PROBE_EVIDENCE=') for line in result.stdout.decode().splitlines()
             if line.startswith('R5E_PROBE_EVIDENCE=')]
    if result.returncode or len(lines) != 1:
        raise RuntimeError('canonical correlation failed; raw RPC output withheld')
    return json.loads(lines[0])


def secret_strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from secret_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from secret_strings(child)
    elif isinstance(value, str) and len(value) >= 16:
        yield value


def safe_evidence(evidence, secrets):
    encoded = json.dumps(evidence, indent=2, sort_keys=True) + '\n'
    if any(secret in encoded for secret in secrets):
        raise RuntimeError('credential value detected in evidence; refused to write')
    if re.search(r'(?i)bearer\s+\S+|sk-(?:ant-)?[A-Za-z0-9_-]{12,}|eyJ[A-Za-z0-9_-]{20,}\.', encoded):
        raise RuntimeError('credential-shaped value detected in evidence; refused to write')
    return encoded


def run(profile_path):
    os.umask(0o077)
    root = Path(__file__).resolve().parent
    profile_path = profile_path.resolve()
    profile = json.loads(profile_path.read_text())
    client = profile['client']
    if client not in ('codex', 'claude'):
        raise ValueError('unsupported probe client')
    gateway = os.environ['R5E_LIVE_GATEWAY_CONTAINER']
    network = os.environ['R5E_LIVE_NETWORK']
    image = os.environ['R5E_LIVE_CLIENT_IMAGE']
    auth_path = Path(os.environ['R5E_LIVE_AUTH_FILE']).resolve()
    output_dir = Path(os.environ.get('R5E_PROBE_EVIDENCE_DIR', root.parent.parent / 'test/live/evidence'))
    if auth_path.stat().st_mode & 0o077:
        raise RuntimeError('auth-only file must be private to its owner')
    auth = json.loads(auth_path.read_text())
    if client == 'codex':
        if auth.get('auth_mode') != 'chatgpt' or not auth.get('tokens'):
            raise RuntimeError('ChatGPT subscription auth required; no API-key fallback')
        auth = {key: auth[key] for key in ('auth_mode', 'tokens', 'last_refresh') if key in auth}
        auth_target = '/home/node/.codex/auth.json'
    else:
        auth = {'claudeAiOauth': auth['claudeAiOauth']}
        if not auth['claudeAiOauth'].get('accessToken'):
            raise RuntimeError('Claude subscription auth required; no API-key fallback')
        auth_target = '/home/node/.claude/.credentials.json'
    secrets = list(secret_strings(auth))
    endpoint_check = Path(os.environ.get('R5E_LIVE_ENDPOINT_CHECK', root / 'check_endpoints.sh'))
    gate = command(['bash', str(endpoint_check)])
    if gate.returncode:
        raise RuntimeError('endpoint selection gate failed; no auth provisioned')
    selection = json.loads(gate.stdout)
    marker = 'R5E_' + client.upper() + '_PROBE_' + uuid.uuid4().hex
    container = 'r5e-probe-' + client + '-' + uuid.uuid4().hex
    evidence = {
        'format': 'r5e-subscription-probe/v1', 'client': client,
        'cli_version': profile['version'], 'auth_mode': profile['auth_mode'],
        'outcome': 'not_started', 'marker': marker,
        'refresh': 'unverified', 'isolation': 'fresh container default home; auth-only provisioning',
        'profile_sha256': hashlib.sha256(profile_path.read_bytes()).hexdigest(),
        'configuration_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [profile_path.parent / name for name in profile['config_files']]},
        'endpoint_selection_observed_at': selection['observed_at'],
        'selected_upstream': selection['routes'][client]['upstream_host'],
    }
    created = False
    try:
        start = command(['docker', 'run', '-d', '--name', container, '--network', network,
                         '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                         '--mount', f'type=bind,src={profile_path.parent},dst=/probe,readonly',
                         image, 'sleep', '300'])
        if start.returncode:
            raise RuntimeError('isolated client container failed to start')
        created = True
        image_id = command(['docker', 'inspect', container, '--format', '{{.Image}}'])
        evidence['client_image_id'] = image_id.stdout.decode().strip()
        version = command(['docker', 'exec', container, client, '--version'])
        if version.returncode or version.stdout.decode().strip() != profile['version']:
            raise RuntimeError('client version differs from the pinned profile')
        provision = command(['docker', 'exec', '-i', container, 'sh', '-c',
                             'umask 077; mkdir -p ' + str(Path(auth_target).parent) + '; cat > ' + auth_target],
                            input=json.dumps(auth).encode())
        if provision.returncode:
            raise RuntimeError('minimal auth provisioning failed')
        if client == 'codex':
            cfg = command(['docker', 'exec', container, 'cp', '/probe/config.toml', '/home/node/.codex/config.toml'])
            if cfg.returncode:
                raise RuntimeError('isolated configuration provisioning failed')
        status_args = ['codex', 'login', 'status'] if client == 'codex' else ['claude', '--safe-mode', '--setting-sources', '', '--settings', '/probe/settings.json', 'auth', 'status']
        status = command(['docker', 'exec', container, *status_args])
        if client == 'codex':
            subscription = b'Logged in using ChatGPT' in status.stdout + status.stderr
        else:
            mode = json.loads(status.stdout)
            subscription = mode.get('loggedIn') is True and mode.get('authMethod') == 'claude.ai'
        if status.returncode or not subscription:
            raise RuntimeError('isolated client did not select subscription auth')
        evidence['subscription_auth_verified'] = True
        prompt = 'You are performing a gateway connectivity test. No tools are available or needed. Reply with exactly this marker and nothing else: ' + marker
        evidence['outcome'] = 'outcome_unknown'
        result = command(['docker', 'exec', container, *profile['argv'], prompt], timeout=120)
        after = command(['docker', 'exec', container, 'cat', auth_target])
        if after.returncode == 0:
            refreshed_auth = json.loads(after.stdout)
            secrets.extend(secret_strings(refreshed_auth))
            before_token = auth.get('tokens', {}).get('access_token') if client == 'codex' else auth['claudeAiOauth']['accessToken']
            after_token = refreshed_auth.get('tokens', {}).get('access_token') if client == 'codex' else refreshed_auth.get('claudeAiOauth', {}).get('accessToken')
            if after_token and before_token != after_token:
                evidence['refresh'] = 'observed_access_token_rotation'
        if result.returncode:
            # Fixed classification only; raw CLI errors can carry request data.
            if b'OAuth session expired and could not be refreshed' in result.stdout:
                evidence.update(outcome='blocked', blocker='subscription_auth_expired_refresh_failed', refresh='failed')
            else:
                evidence.update(outcome='blocked', blocker='client_nonzero_exit', client_exit_code=result.returncode)
        else:
            if client == 'codex':
                output = command(['docker', 'exec', container, 'cat', '/tmp/probe-result.txt'])
                matches = output.returncode == 0 and output.stdout.decode().strip() == marker
            else:
                parsed = json.loads(result.stdout)
                matches = not parsed.get('is_error', True) and parsed.get('result', '').strip() == marker
            if not matches:
                raise RuntimeError('client output did not match the probe marker')
            evidence['canonical'] = collect(gateway, client, marker, root)
            evidence.update(outcome='passed', client_response_matches_marker=True)
    except subprocess.TimeoutExpired:
        evidence.update(outcome='outcome_unknown', blocker='probe_timeout_no_automatic_retry')
    except (RuntimeError, ValueError, KeyError):
        # Do not stringify exceptions, since parsing failures may include secrets.
        evidence.update(outcome='blocked', blocker='probe_setup_or_evidence_validation_failed')
    finally:
        if created:
            try:
                removed = command(['docker', 'rm', '-f', container])
                if removed.returncode:
                    evidence['cleanup'] = 'failed; inspect isolated probe container'
            except subprocess.TimeoutExpired:
                evidence['cleanup'] = 'timeout; inspect isolated probe container'
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / (client + '-probe.json')
    destination.write_text(safe_evidence(evidence, secrets))
    print(json.dumps({'client': client, 'outcome': evidence['outcome'], 'evidence': str(destination)}))
    return 0 if evidence['outcome'] == 'passed' else 1


if __name__ == '__main__':
    try:
        sys.exit(run(Path(sys.argv[1])))
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.TimeoutExpired):
        print('Probe preflight failed; no raw configuration or credential output emitted', file=sys.stderr)
        sys.exit(2)
