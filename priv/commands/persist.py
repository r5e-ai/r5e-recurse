#!/usr/bin/env python3
"""Persist non-secret uncertainty marker, including its directory entry."""
import os
import sys
path, digest = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.write(fd, digest.encode('ascii'))
    os.fsync(fd)
finally:
    os.close(fd)
fd = os.open(os.path.dirname(path), os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)

fd = os.open(os.path.dirname(os.path.dirname(path)), os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
