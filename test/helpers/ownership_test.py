# SPDX-License-Identifier: AGPL-3.0-only
"""Deterministic helper persistence and framing checks; no live chain."""
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ownership', pathlib.Path(__file__).parents[2] / 'priv/commands/ownership.py')
owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owner)

class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = self.temp.name + '/intent.pending'
        self.data = b'sha256:' + b'0' * 64

    def test_atomic_publish_is_exclusive_and_validates_existing_bytes(self):
        owner.publish(self.path, self.data)
        self.assertEqual(owner.read_marker(self.path), self.data.decode())
        with self.assertRaises(FileExistsError):
            owner.publish(self.path, b'sha256:' + b'1' * 64)
        self.assertEqual(pathlib.Path(self.path).read_bytes(), self.data)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        self.assertEqual(list(pathlib.Path(self.temp.name).iterdir()), [pathlib.Path(self.path)])

    def test_partial_and_symlink_markers_fail_closed(self):
        pathlib.Path(self.path).write_bytes(b'sha256:partial')
        with self.assertRaises(ValueError):
            owner.read_marker(self.path)
        os.unlink(self.path)
        os.symlink('/dev/null', self.path)
        with self.assertRaises(OSError):
            owner.read_marker(self.path)

    def test_file_fsync_failure_never_publishes(self):
        with patch.object(owner.os, 'fsync', side_effect=OSError('injected')):
            with self.assertRaises(OSError):
                owner.publish(self.path, self.data)
        self.assertFalse(os.path.exists(self.path))

    def test_directory_fsync_failure_preserves_published_intent(self):
        with patch.object(owner, 'syncdir', side_effect=OSError('injected')):
            with self.assertRaises(OSError):
                owner.publish(self.path, self.data)
        self.assertEqual(pathlib.Path(self.path).read_bytes(), self.data)

    def test_nesting_limit(self):
        value = None
        for _ in range(65):
            value = [value]
        with self.assertRaises(ValueError):
            owner.depth(value)


import base64
import json
import socket
import struct
import subprocess
import threading
import time

class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.addCleanup(self.listener.close)
        self.url = 'http://127.0.0.1:' + str(self.listener.getsockname()[1])
        self.lifetime = 'a' * 64
        self.token = 'b' * 64
        self.origin = 'sha256:' + 'c' * 64
        self.marker = 'sha256:' + 'd' * 64
        self.payload = 'sha256:' + 'e' * 64
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)

    def start(self, timeout=2000):
        process = subprocess.Popen(['python3', owner.__file__, self.temp.name, self.lifetime,
            self.origin, self.url, str(timeout)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.processes.append(process)
        return process

    def receive(self, process):
        header = process.stdout.read(4)
        if not header:
            return None
        size = struct.unpack('!I', header)[0]
        return json.loads(process.stdout.read(size))

    def send(self, process, message):
        data = json.dumps({'version': 1, **message}).encode()
        process.stdin.write(struct.pack('!I', len(data)) + data)
        process.stdin.flush()

    def dispatch(self, process, mode='normal'):
        body = json.dumps({'name': None, 'spec': {'payloadDigest': self.payload, 'commandId': 'command'},
                           'envelope': {}}).encode()
        self.send(process, {'type': 'dispatch', 'lifetime': self.lifetime, 'token': self.token,
            'mode': mode, 'body': base64.b64encode(body).decode(), 'body_digest': owner.digest(body),
            'envelope_digest': owner.digest(b'{}'), 'marker': self.marker, 'caller': 'caller', 'nonce': 'nonce'})

    def server(self, response=None, received=None, release=None):
        def run():
            conn, _ = self.listener.accept()
            with conn:
                data = b''
                while b'\r\n\r\n' not in data:
                    data += conn.recv(16384)
                if received:
                    received.set()
                if release:
                    release.wait(3)
                if response:
                    try:
                        conn.sendall(response)
                    except OSError:
                        pass
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def test_wrong_finalize_token_preserves_marker_and_poison_exits(self):
        self.server(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}')
        process = self.start()
        self.assertEqual(self.receive(process)['type'], 'ready')
        self.dispatch(process)
        self.assertEqual(self.receive(process)['type'], 'response')
        self.send(process, {'type': 'finalize', 'lifetime': self.lifetime, 'token': 'f' * 64, 'action': 'remove'})
        self.assertNotEqual(process.wait(timeout=2), 0)
        self.assertTrue(pathlib.Path(self.temp.name, self.marker + '.pending').exists())

    def test_missing_finalize_preserves_replay_sidecar_and_exits(self):
        self.server(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}')
        process = self.start()
        self.receive(process)
        self.dispatch(process, 'replay')
        self.assertEqual(self.receive(process)['type'], 'response')
        process.wait(timeout=2)
        sidecar = pathlib.Path(self.temp.name, 'replay-v1', self.token + '.json')
        self.assertEqual(json.loads(sidecar.read_text())['attempt_id'], self.token)
        self.assertFalse(pathlib.Path(self.temp.name, self.marker + '.pending').exists())

    def test_closed_control_cannot_release_lock_while_http_is_paused(self):
        received, release = threading.Event(), threading.Event()
        self.server(received=received, release=release)
        process = self.start(timeout=500)
        self.receive(process)
        self.dispatch(process)
        self.assertTrue(received.wait(2))
        process.stdin.close()
        process.stdin = None
        replacement = self.start()
        self.assertNotEqual(replacement.wait(timeout=2), 0)
        process.wait(timeout=2)
        replacement = self.start()
        self.assertEqual(self.receive(replacement)['type'], 'ready')
        release.set()

    def test_partial_frame_watchdog_during_finalize(self):
        self.server(b'HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\n{}')
        process = self.start()
        self.receive(process)
        self.dispatch(process)
        self.receive(process)
        process.stdin.write(struct.pack('!I', 20) + b'{')
        process.stdin.flush()
        self.assertNotEqual(process.wait(timeout=2), 0)
        self.assertTrue(pathlib.Path(self.temp.name, self.marker + '.pending').exists())

    def test_slow_progress_does_not_refresh_absolute_deadline(self):
        stopped = threading.Event()
        def drip():
            conn, _ = self.listener.accept()
            with conn:
                conn.recv(16384)
                for byte in b'HTTP/1.1 201 Created\r\nContent-Length: 20\r\n\r\n' + b'x' * 20:
                    try:
                        conn.sendall(bytes([byte]))
                    except OSError:
                        break
                    if stopped.wait(0.03):
                        break
        thread = threading.Thread(target=drip, daemon=True)
        thread.start()
        process = self.start(timeout=250)
        self.receive(process)
        started = time.monotonic()
        self.dispatch(process)
        self.assertNotEqual(process.wait(timeout=1.5), 0)
        self.assertLess(time.monotonic() - started, 1.0)
        stopped.set()
        self.assertTrue(pathlib.Path(self.temp.name, self.marker + '.pending').exists())

if __name__ == '__main__':
    unittest.main()
