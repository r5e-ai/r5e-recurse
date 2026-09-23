# Native cooperative launcher (R5E-220, T055–T057)

This slice implements argument-vector execution, local byte capture and observed
cooperative process-group cleanup. It does not perform model/provider calls,
authorize launch, admit artifacts, or make workflow success decisions. The caller
must admit the binding and launch context before `start`, including the effective
budgets returned by `prepare`. A nonempty launch reference is a trusted caller
input, not a second admission verifier.

`LocalCLI.prepare` accepts an absolute executable, argument list, explicit
workload environment, workspace and existing trusted spool parent directory in
`Session.adapter_options`. The workload receives only the supplied environment;
its stdin is the exact rendered input file. Preparation creates a unique private
spool but launches nothing. `result_file`, if supplied, is a relative path under
the newly created private spool root. The caller can use that root in the prepared
argument vector; the result file is never interpreted relative to ambient CWD.
The adapter does not provision provider credentials or claim harness isolation.

The broker belongs to the stable execution worker, not its transient callback.
An independent guardian kills the broker on worker death, so blocked spool I/O
cannot postpone closing the helper control pipe.
Its live capability contains a broker PID and an unguessable reference. The native
helper controller retains a child group anchor until it has issued all group
signals. The anchor reserves the group ID, creates the workload only after READY
and GO, and stays alive through target exit. Workload signal dispositions and
masks are reset before exec. TERM is followed by KILL while the anchor remains
unreaped; there is no signal based on a stored/recovered group ID after reaping.
A group-disappearance probe after reaping is observational only. A lingering or
ambiguous group yields unknown. PIDs in diagnostic identity files never authorize
recovery signals. Deliberately detached descendants and helper SIGKILL are outside
this cooperative profile; no hard containment is claimed.

Ordinary controller TERM/INT/HUP requests bounded group cleanup in the main
loop; only uncatchable helper death is excluded. BEAM death, worker death or
closed control pipes independently trigger native
cleanup. Startup and output ACK waits are bounded. Output backpressure cannot
prevent processing cancellation/control EOF. Natural target exit still cleans up
remaining cooperative descendants and bounds pipe draining; inherited writer FDs
cannot hold completion forever. Production grace and drain windows are 5 seconds
each. Explicit bounded test overrides are carried in the prepared session. An
omitted callback deadline becomes grace + drain + 2 seconds (12 seconds by
default); an explicitly insufficient deadline refuses preparation. Idle/hard
execution timers remain the supervisor's independent timers.

Protocol version 1 uses a 32-bit big-endian length prefix. Configuration is capped
at 1 MiB. Output frames carry a type and 64-bit global sequence; raw stdout,
stderr and final-file frames contain at most 64 KiB of uninterpreted bytes. The
helper permits one unacknowledged raw frame. The broker acknowledges only after
local chunk and completion-index sync. A failed write acknowledges solely to
release backpressure while requesting stop and marking incomplete capture.
No raw stream bytes are parsed as helper controls. OS wait status, capture
completeness and cleanup are distinct outcome fields. A missing target wait
status produces `capture_incomplete`, never a fabricated `os_exit` event.
A narrow correction to the previously reviewed Worker preserves a sanitized
observed exit/signal together with incomplete capture when later reconciliation
times out; existing single exit-code and incomplete-only outcomes keep their shape.
The terminal pair is indivisible across observation batches; batches remain at
most 32 observations, so a near-full raw batch defers the complete terminal pair.

Each immutable raw chunk is below the 8 MiB contract ceiling. A 64 MiB payload
budget counts rendered input, explicitly reserved request bytes and captured
output. `LocalCLI.account_request` reserves future bridge request bytes before
those requests dispatch; unreported provider bytes are outside the current
measurement. Chunk/index counts and framing buffers have independent bounds.
The optional JSON-line framer buffers split JSON/UTF-8 within its cap and cites
sequence/byte ranges; it attaches no provider-specific completion meaning.

The spool is a diagnostic record, not canonical authority. Immutable prepared,
reservation, chunk-intent, chunk-complete and terminal index files preserve
accounting and crash boundaries. Missing/partial terminal or index records and
uncompleted writes remain incomplete. Recovery validates retained chunk hashes;
it does not infer successful execution from bytes or restore a live route.
Files are synced before acknowledgment; this slice does not claim power-loss
atomicity for directory entries. Index records are not cryptographic receipts.
Final files are opened beneath the configured private root using per-component
nofollow and same-FD regular-file checks and bounded reads, including FIFO refusal,
before any caller cleanup. Temporary evidence is not automatically deleted.

Native fixtures compile the helper on macOS and Linux. They test real child and
grandchild behavior, control EOF while output is unacknowledged, inherited signal
masks, premature anchor exit, bounded startup failure, nonzero exit, final-file
and symlink/FIFO cases. The production binary contains no startup fault injection;
those two cases use a separately compiled `R5E_LAUNCH_TEST` binary. Linux containers
may retain reparented zombies; that condition is reported conservatively as
unknown rather than promoted to proof of group disappearance.
