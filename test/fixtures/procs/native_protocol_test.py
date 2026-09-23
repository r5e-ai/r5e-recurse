# SPDX-License-Identifier: AGPL-3.0-only
"""Native macOS/Linux helper tests; no providers, process recovery or live chains."""
import os, pathlib, select, signal, struct, subprocess, sys, tempfile, time, unittest
HELPER = sys.argv.pop(1)
def number(n): return struct.pack('!I', n)
def string(s):
    b = os.fsencode(s)
    return number(len(b)) + b
def strings(xs): return number(len(xs)) + b''.join(map(string, xs))
def inherited_signals():
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM, signal.SIGUSR1])
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
class Run:
    def __init__(self, args, budget=1048576, final='', go=True, blocked=False):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / 'input').write_bytes(b'')
        self.p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=inherited_signals if blocked else None)
        config = b'S'+number(1)+string(self.root)+string(self.root)+string('input')+string(self.root)+string(final)+strings(args)+strings(['PATH=/usr/bin:/bin'])+number(budget)+number(100)+number(500)
        self.send(config)
        tag,seq,payload = self.frame()
        assert tag == b'R' and seq == 0
        version,self.group = struct.unpack('!II',payload)
        assert version == 1
        self.raw = {b'O':b'', b'E':b'', b'L':b''}
        if go: self.send(b'G')
    def send(self, data):
        self.p.stdin.write(number(len(data))+data); self.p.stdin.flush()
    def exact(self,n):
        data=b''; until=time.monotonic()+4
        while len(data)<n:
            remaining=until-time.monotonic()
            if remaining<=0 or not select.select([self.p.stdout],[],[],remaining)[0]: raise AssertionError('protocol timeout')
            more=os.read(self.p.stdout.fileno(),n-len(data))
            if not more: raise AssertionError('unexpected helper EOF: '+str(self.p.poll()))
            data+=more
        return data
    def frame(self):
        n=struct.unpack('!I',self.exact(4))[0]
        assert n<=65545
        data=self.exact(n)
        return data[:1],struct.unpack('!Q',data[1:9])[0],data[9:]
    def finish(self):
        while True:
            tag,seq,payload=self.frame()
            if tag in self.raw:
                self.raw[tag]+=payload;self.send(b'A'+struct.pack('!Q',seq))
            elif tag==b'F':
                result=struct.unpack('!iIII',payload)
                self.p.wait(timeout=3)
                return result
            else: raise AssertionError(tag)
    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            self.p.wait(timeout=3)
        for f in [self.p.stdin,self.p.stdout,self.p.stderr]:
            if not f.closed:f.close()
        self.temp.cleanup()
class Protocol(unittest.TestCase):
    def run_fixture(self,args,**kw):
        r=Run(args,**kw);self.addCleanup(r.close);return r
    def test_streams_and_nonzero(self):
        r=self.run_fixture(['/bin/sh','-c','printf done; printf noise >&2; exit 9'])
        self.assertEqual(r.finish(),(9,0,0,0));self.assertEqual(r.raw[b'O'],b'done');self.assertEqual(r.raw[b'E'],b'noise')
    def test_term_disposition_is_reset(self):
        r=self.run_fixture(['/bin/sh','-c','echo ready; exec /bin/sleep 20'],blocked=True)
        tag,seq,_=r.frame();self.assertEqual(tag,b'O');r.send(b'A'+struct.pack('!Q',seq));r.send(b'C');code,sig,cap,clean=r.finish()
        self.assertEqual(sig,signal.SIGTERM);self.assertEqual(cap,0);self.assertEqual(clean,0)
    def test_owner_pipe_death_stops_child_and_grandchild(self):
        r=self.run_fixture(['/bin/sh','-c','(while :; do echo beat; sleep .02; done) & wait'])
        tag,seq,data=r.frame();self.assertEqual(tag,b'O')
        r.p.stdin.close();r.p.wait(timeout=3)
        if sys.platform=='darwin':
            with self.assertRaises(ProcessLookupError):os.killpg(r.group,0)
    def test_anchor_death_is_incomplete_and_bounded(self):
        r=self.run_fixture(['/bin/sleep','20'],go=False)
        os.kill(r.group,signal.SIGKILL)
        code,sig,cap,clean=r.finish();self.assertEqual(cap,1)
    def test_remaining_descendant_is_cleaned_on_parent_exit(self):
        r=self.run_fixture(['/bin/sh','-c','sleep 20 & exit 0'])
        code,sig,cap,clean=r.finish();self.assertEqual(code,0)
        if sys.platform=='darwin':
            with self.assertRaises(ProcessLookupError):os.killpg(r.group,0)
    def test_budget_is_incomplete(self):
        r=self.run_fixture(['/bin/sh','-c','printf 123456789'],budget=4)
        self.assertEqual(r.finish()[2],1)
    def test_final_file_and_symlink_refusal(self):
        r=self.run_fixture(['/bin/sh','-c','printf result > answer'],final='answer')
        self.assertEqual(r.finish(),(0,0,0,0));self.assertEqual(r.raw[b'L'],b'result')
        r=self.run_fixture(['/bin/sh','-c','ln -s /etc/passwd answer'],final='answer')
        self.assertEqual(r.finish()[2],1);self.assertEqual(r.raw[b'L'],b'')
    def test_backpressured_output_control_eof_and_fifo_final(self):
        r=self.run_fixture(['/bin/sh','-c','yes x'])
        tag,seq,data=r.frame();self.assertEqual(tag,b'O')
        # Deliberately do not ACK; control EOF must still terminate the group.
        r.p.stdin.close();r.p.wait(timeout=3)
        if sys.platform=='darwin':
            with self.assertRaises(ProcessLookupError):os.killpg(r.group,0)
        r=self.run_fixture(['/bin/sh','-c','mkfifo answer'],final='answer')
        self.assertEqual(r.finish()[2],1)
    def test_final_parent_directory_symlink_refused(self):
        r=self.run_fixture(['/bin/sh','-c','ln -s /etc outside'],final='outside/passwd')
        self.assertEqual(r.finish()[2],1)
    def test_controller_term_int_hup_request_group_cleanup(self):
        for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
            r=self.run_fixture(['/bin/sh','-c','echo ready; exec /bin/sleep 20'])
            tag,seq,_=r.frame();self.assertEqual(tag,b'O');r.send(b'A'+struct.pack('!Q',seq))
            os.kill(r.p.pid,sig)
            code,term,cap,clean=r.finish()
            self.assertEqual(term,signal.SIGTERM)
            self.assertEqual((cap,clean),(0,0))
    def test_stop_before_go_never_releases_workload(self):
        for stop in ['signal','control']:
            r=self.run_fixture(['/bin/sh','-c','touch launched'],go=False)
            if stop=='signal':os.kill(r.p.pid,signal.SIGTERM)
            else:r.send(b'C')
            r.send(b'G')
            # A rejected GO may close protocol as an invalid late control. Either
            # terminal framing or EOF is allowed; workload must never start.
            try:r.finish()
            except AssertionError:r.p.wait(timeout=3)
            self.assertFalse((r.root/'launched').exists())
            if sys.platform=='darwin':
                with self.assertRaises(ProcessLookupError):os.killpg(r.group,0)
    def test_workload_clears_noncontroller_inherited_signal_mask(self):
        r=self.run_fixture(['/bin/sh','-c','echo ready; exec /bin/sleep 20'],blocked=True)
        tag,seq,_=r.frame();self.assertEqual(tag,b'O');r.send(b'A'+struct.pack('!Q',seq))
        os.killpg(r.group,signal.SIGUSR1)
        code,term,cap,clean=r.finish()
        self.assertEqual(term,signal.SIGUSR1)
        self.assertEqual((cap,clean),(0,0))
    def test_missing_exec_is_nonzero(self):
        r=self.run_fixture(['/no/such/program']);self.assertEqual(r.finish()[0],127)
if __name__=='__main__':unittest.main()
