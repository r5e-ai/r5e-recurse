# SPDX-License-Identifier: AGPL-3.0-only
"""Run only against a binary built with -DR5E_LAUNCH_TEST."""
import os, pathlib, struct, subprocess, sys, tempfile, time
helper=sys.argv[1]
def n(x):return struct.pack('!I',x)
def s(x):
 b=os.fsencode(x);return n(len(b))+b
for fault in ['exit','hang']:
 with tempfile.TemporaryDirectory() as root:
  pathlib.Path(root,'input').write_bytes(b'')
  data=b'S'+n(1)+s(root)+s(root)+s('input')+s(root)+s('')+n(1)+s('/bin/true')+n(0)+n(100)+n(100)+n(100)
  start=time.monotonic()
  p=subprocess.run([helper],input=n(len(data))+data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={**os.environ,'R5E_LAUNCH_TEST_BEFORE_READY':fault},timeout=4)
  assert p.returncode==2 and p.stdout==b''
  assert time.monotonic()-start<3
print('2 startup failure cases passed')
