#!/usr/bin/env python3
"""One cooperative host namespace; OS releases the lock on helper death."""
import fcntl
import os
import stat
import sys

path = sys.argv[1]
try:
    os.mkdir(path, 0o700)
except FileExistsError:
    pass
info = os.lstat(path)
if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
    sys.exit(2)
fd = os.open(path + "/writer.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("busy", flush=True)
    sys.exit(3)
print("acquired", flush=True)
while sys.stdin.buffer.read(4096):
    pass
