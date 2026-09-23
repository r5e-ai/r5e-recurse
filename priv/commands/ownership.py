#!/usr/bin/env python3
"""Single process owns publication, transport and cleanup under one flock."""
import base64
import fcntl
import hashlib
import http.client
import json
import os
import re
import signal
import ssl
import stat
import struct
import sys
import time
import urllib.parse

MAX_FRAME = 16 * 1024 * 1024
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')

def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()

def deadline(ms):
    # SIGALRM terminates this entire lock-owning process, including blocked DNS/fsync.
    signal.setitimer(signal.ITIMER_REAL, ms / 1000)

def syncdir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def directory(path):
    try:
        os.mkdir(path, 0o700)
        syncdir(os.path.dirname(path))
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe directory')

def publish(path, data):
    temp = path + '.tmp-' + os.urandom(16).hex()
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.link(temp, path, follow_symlinks=False)
        syncdir(os.path.dirname(path))
    finally:
        os.unlink(temp)

def read_marker(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as inp:
        if not stat.S_ISREG(os.fstat(inp.fileno()).st_mode):
            raise ValueError('nonregular marker')
        data = inp.read(72)
    if len(data) != 71 or not DIGEST.fullmatch(data.decode('ascii')):
        raise ValueError('malformed marker')
    return data.decode('ascii')

def depth(value, level=0):
    if level > 64:
        raise ValueError('nesting')
    if isinstance(value, dict):
        for item in value.values():
            depth(item, level + 1)
    elif isinstance(value, list):
        for item in value:
            depth(item, level + 1)

def read_exact(count):
    data = b''
    while len(data) < count:
        part = sys.stdin.buffer.read(count - len(data))
        if not part:
            raise EOFError()
        data += part
    return data

def receive():
    first = read_exact(1)
    if signal.getitimer(signal.ITIMER_REAL)[0] == 0:
        deadline(1000)
    size = struct.unpack('!I', first + read_exact(3))[0]
    if not 0 < size <= MAX_FRAME:
        raise ValueError('frame size')
    msg = json.loads(read_exact(size))
    depth(msg)
    if msg.get('version') != 1:
        raise ValueError('version')
    return msg

def emit(msg):
    msg['version'] = 1
    data = json.dumps(msg, separators=(',', ':')).encode()
    if len(data) > 128 * 1024:
        raise ValueError('response frame')
    sys.stdout.buffer.write(struct.pack('!I', len(data)) + data)
    sys.stdout.buffer.flush()

class BoundedResponse(http.client.HTTPResponse):
    def begin(self):
        # http.client already caps lines and field count; additionally cap total bytes.
        original = self.fp
        class Reader:
            def __init__(self):
                self.total = 0
            def readline(self, limit=-1):
                line = original.readline(min(limit if limit >= 0 else 32769, 32769))
                self.total += len(line)
                if self.total > 32768:
                    raise ValueError('headers too large')
                return line
            def __getattr__(self, key):
                return getattr(original, key)
        self.fp = Reader()
        super().begin()

def transport(url, body, until):
    parsed = urllib.parse.urlsplit(url)
    cls = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
    kwargs = {'timeout': max(0.001, until - time.monotonic())}
    if parsed.scheme == 'https':
        kwargs['context'] = ssl.create_default_context()
    conn = cls(parsed.hostname, parsed.port, **kwargs)
    conn.response_class = BoundedResponse
    try:
        conn.putrequest('POST', parsed.path.rstrip('/') + '/apis/recurse.r5e.io/v1alpha1/Command', skip_accept_encoding=True)
        conn.putheader('Content-Type', 'application/json')
        conn.putheader('Connection', 'close')
        conn.putheader('Content-Length', str(len(body)))
        conn.endheaders(body)
        response = conn.getresponse()
        data = response.read(65537)
        if len(data) > 65536:
            raise ValueError('response too large')
        try:
            depth(json.loads(data))
        except json.JSONDecodeError:
            pass  # Shared decoder determines malformed-receipt semantics.
        return {'status': response.status, 'body': base64.b64encode(data).decode()}
    finally:
        conn.close()

def main():
    path, lifetime, origin, url, timeout = sys.argv[1:]
    timeout = int(timeout)
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or not 1 <= timeout <= 15000:
        raise ValueError('endpoint')
    deadline(5000)
    directory(path)
    lock = os.open(path + '/writer.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sentinel = path + '/format.json'
    try:
        publish(sentinel, b'{"version":1,"replay":"replay-v1"}')
    except FileExistsError:
        fd = os.open(sentinel, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as inp:
            if not stat.S_ISREG(os.fstat(inp.fileno()).st_mode):
                raise ValueError('unsafe format')
            if inp.read(100) != b'{"version":1,"replay":"replay-v1"}':
                raise ValueError('unknown format')
    directory(path + '/replay-v1')
    deadline(0)
    emit({'type': 'ready'})
    while True:
        msg = receive()
        deadline(timeout)
        until = time.monotonic() + timeout / 1000
        if msg.get('type') != 'dispatch' or msg.get('lifetime') != lifetime:
            raise ValueError('dispatch protocol')
        token, mode = msg['token'], msg['mode']
        if not re.fullmatch('[0-9a-f]{64}', token) or mode not in ('normal', 'replay'):
            raise ValueError('attempt')
        body = base64.b64decode(msg['body'], validate=True)
        if len(body) > 8 * 1024 * 1024 or digest(body) != msg['body_digest']:
            raise ValueError('body digest')
        request = json.loads(body)
        depth(request)
        spec, envelope = request['spec'], request['envelope']
        if set(request) != {'spec', 'envelope', 'name'} or request['name'] is not None:
            raise ValueError('body')
        payload = spec['payloadDigest']
        if not DIGEST.fullmatch(payload) or not re.fullmatch('sha256:[0-9a-f]{64}', msg['marker']):
            raise ValueError('marker')
        marker = path + '/' + msg['marker'] + '.pending'
        data = payload.encode()
        if mode == 'replay':
            marker = path + '/replay-v1/' + token + '.json'
            data = json.dumps({'version': 1, 'mode': mode, 'attempt_id': token, 'origin': origin,
                'caller': msg['caller'], 'scoped_command_id': spec['commandId'], 'payload_digest': payload,
                'nonce': msg['nonce'], 'envelope_digest': msg['envelope_digest'],
                'body_digest': digest(body)}, separators=(',', ':')).encode()
        try:
            publish(marker, data)
        except FileExistsError:
            if mode != 'normal':
                raise ValueError('attempt collision')
            existing = read_marker(marker)
            emit({'type': 'pending', 'token': token, 'same': existing == payload})
            deadline(0)
            continue
        marker_digest = digest(data)
        try:
            result = transport(url, body, until)
        except Exception:
            result = {'transport_error': True}
        emit({'type': 'response', 'token': token, **result})
        deadline(1000)
        final = receive()
        if final != {'version': 1, 'type': 'finalize', 'lifetime': lifetime, 'token': token, 'action': final.get('action')} or final['action'] not in ('retain', 'remove'):
            raise ValueError('finalize protocol')
        if final['action'] == 'remove':
            fd = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as inp:
                if not stat.S_ISREG(os.fstat(inp.fileno()).st_mode) or digest(inp.read(MAX_FRAME)) != marker_digest:
                    raise ValueError('marker changed')
            os.unlink(marker)
            syncdir(os.path.dirname(marker))
        emit({'type': 'finalized', 'token': token})
        deadline(0)

if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt):
        sys.exit(2)
