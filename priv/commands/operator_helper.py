#!/usr/bin/env python3
"""Bounded argv transport. Diagnostics never enter the signature channel."""
import os
import selectors
import signal
import subprocess
import sys
import time

sys.stderr = open(os.devnull, "w")
limit = int(sys.argv[1])
timeout = int(sys.argv[2]) / 1000
argv = sys.argv[3:]
message = sys.stdin.buffer.readline(1024 * 1024 + 1)
if len(message) > 1024 * 1024:
    sys.exit(4)
process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, start_new_session=True)
try:
    selector = selectors.DefaultSelector()
    os.set_blocking(process.stdin.fileno(), False)
    selector.register(process.stdin, selectors.EVENT_WRITE)
    selector.register(process.stdout, selectors.EVENT_READ)
    sent = 0
    deadline = time.monotonic() + timeout
    output = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            sys.exit(5)
        ready = selector.select(remaining)
        if not ready:
            sys.exit(5)
        finished = False
        for key, _ in ready:
            if key.fileobj is process.stdin:
                try:
                    sent += os.write(process.stdin.fileno(), message[sent:])
                except BrokenPipeError:
                    sent = len(message)
                if sent == len(message):
                    selector.unregister(process.stdin)
                    process.stdin.close()
            else:
                chunk = os.read(process.stdout.fileno(), min(4096, limit + 1))
                if not chunk:
                    finished = True
                    break
                output.extend(chunk)
                if len(output) > limit:
                    sys.exit(6)
        if finished:
            break
    status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
    if status != 0:
        sys.exit(7)
    sys.stdout.buffer.write(output)
finally:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
