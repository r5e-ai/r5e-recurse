#!/usr/bin/env python3
"""Own one journal namespace and publish durable, immutable intent/entry files."""
import http.client
import urllib.parse
import fcntl
import json
import os
import re
import stat
import sys
import tempfile

MAX = 8 * 1024 * 1024
MAX_RECEIPT = 64 * 1024
# Same explicit numeric domain enforced before Elixir reserves an operation.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(1024)

def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def publish(directory, name, content):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}\.(intent|json)", name):
        raise ValueError("invalid name")
    data = content.encode("utf-8")
    if len(data) > MAX:
        raise ValueError("entry too large")
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, os.path.join(directory, name))
        sync_directory(directory)
    finally:
        os.unlink(temporary)

def dispatch(directory, command):
    name = command["name"]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}\.json", name):
        raise ValueError("invalid prepared entry")
    with open(os.path.join(directory, name), encoding="utf-8") as stream:
        entry = json.load(stream)
    url = urllib.parse.urlsplit(command["url"])
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("invalid kernel URL")
    timeout = command["timeout"] / 1000
    if timeout <= 0:
        raise ValueError("invalid timeout")
    target = entry["candidate"]["target"]
    path = url.path.rstrip("/") + "/apis/" + "/".join(urllib.parse.quote_plus(target[k], safe="") for k in ("group", "version", "kind"))
    body = json.dumps({"envelope": entry["envelope"], "spec": entry["candidate"]["spec"], "name": target["name"]}).encode("utf-8")
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    connection = cls(url.hostname, url.port, timeout=timeout)
    try:
        try:
            connection.connect()
        except OSError:
            return "connection_failed"
        # No retries or redirects. This process retains the writer lock through dispatch.
        connection.request("POST", path, body, {"Content-Type": "application/json"})
        response = connection.getresponse()
        # A bounded untrusted locator can survive a later history-read failure.
        # Only canonical history determines the outcome; this is never a grant.
        result = {"status": "acknowledged" if response.status in (201, 403) else "uncertain"}
        raw = response.read(MAX_RECEIPT + 1)
        if len(raw) > MAX_RECEIPT:
            return result
        try:
            receipt = json.loads(raw)
            ref = receipt.get("eventRef") if isinstance(receipt, dict) else None
            if isinstance(ref, str) and re.fullmatch(r"event:sha256:[0-9a-f]{64}", ref):
                result["event_ref_hint"] = ref
        except (ValueError, UnicodeError):
            return result
        return result
    finally:
        connection.close()

def main(directory):
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        return 2
    # The namespace itself must survive, not only the entries within it.
    sync_directory(os.path.dirname(directory))
    lock = os.open(os.path.join(directory, "writer.lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("busy", flush=True)
        return 3
    print("acquired", flush=True)
    while True:
        header = sys.stdin.buffer.read(4)
        if not header:
            return 0
        if len(header) != 4:
            return 4
        length = int.from_bytes(header, "big")
        if length > 2 * MAX:
            return 4
        data = sys.stdin.buffer.read(length)
        if len(data) != length:
            return 4
        command = {}
        try:
            command = json.loads(data)
            if command.get("action") == "dispatch":
                result = dispatch(directory, command)
            else:
                publish(directory, command["name"], command["content"])
                result = "persisted"
            if isinstance(result, str):
                result = {"status": result}
            print(json.dumps({"name": command["name"], **result}), flush=True)
        except Exception:
            # A failed acknowledgement does not imply that publication did not happen.
            print(json.dumps({"name": command.get("name"), "status": "uncertain"}), flush=True)

if __name__ == "__main__":
    sys.exit(main(os.path.abspath(sys.argv[1])))
