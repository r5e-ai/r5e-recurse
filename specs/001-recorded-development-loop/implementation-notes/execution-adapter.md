# T051/T052 execution adapter boundary and fixture

`Execution.Adapter` defines prepared session inputs, invocation, captured handle,
ordered observations, declared capabilities and ownership results. Admission,
authority, artifact success and retry decisions remain coordinator concerns.

The initial contract review identified one concrete preparation gap: real
adapters need executable/isolation-specific configuration, and a scriptable fake
needs its scenario without global mutable state or overloading budgets. Session
therefore has optional trusted `adapter_options: %{}`. Its existing Inspect
allowlist excludes those options, route credentials and rendered input. Ownership
also has an Inspect allowlist exposing only state; opaque spool/identity data is
not accidentally printed. These are the only changes to the primary T051 draft.

The T052 fake lives under `test/support`, compiled only for tests. It launches a
BEAM fixture process; it never launches an OS executable, provider, tool or real
CLI. Missing executable is an injected preparation outcome. Scripted exit codes
are explicitly simulated, while stopped ownership from cancel/observe requires
observed death of that exact fixture process. This is not descendant termination
evidence. An exhausted script or `:hang` yields no observations and never creates
success. A model-completion observation cites prior raw chunk sequence, source,
length and SHA256; its value is scripted, not parsed or independently verified.

Raw stdout/stderr/result-file bytes remain separate and unchanged. Output budgets
bound observed chunk and aggregate size; excess or injected capture failure emits
capture_incomplete and stops the fixture without a synthetic successful exit.
The fixture does not admit artifacts or persist a durable spool. In-memory test
captures cannot establish crash recovery or canonical evidence.

Cancellation can observe stop, refuse, or return unknown while the original
process stays live. Reconciliation probes only the captured PID/token, never
consumes the script or starts a replacement; a bare PID or dead process without
an already observed stop remains unknown. Refusal can be injected independently.
The helper `release/1` advances an existing hang solely for deterministic tests.

Eight tests cover preparation refusal/launch-reference separation, model done
followed by nonzero exit, split UTF8/JSON and stderr/final-file bytes, hang and
uncertain cancellation, observed cancellation and refusal, read-only ownership
inspection, output/capture faults, and secret-safe Inspect/status/evidence. Docker
`r5e/recurse-a1-tests:git`, `MIX_ENV=test`: format and warnings-as-errors compilation
passed; targeted tests 8/0. No host Mix/Hex mounts or live services were used.

T053/T054 remain separate: real execution worker supervision, owner monitoring,
retained generation-tagged idle/hard timers, and no relaunch after restart are
not supplied by this fake. Real adapter isolation, credential provisioning,
process-group cancellation, detached descendant limits, actual streaming parser
behavior and durable capture require their own implementation and measurements.

## T053/T054 temporary execution supervision

The subsequent JJ child adds Execution.Supervisor, Worker and the private
Callback guardian. No Application child starts execution automatically. Explicit
start_execution returns a starting worker; the original Session.owner is fixed
as the submitting caller/event sink. The adapter receives the stable Worker as
its local execution owner, while the submitting caller is independently monitored.
The prepared budget overrides are retained; default idle/hard budgets are 5/30
minutes. This supervision step does not admit or manufacture launch evidence.

A single bounded callback runs at a time. An independent guardian monitors the
Worker and callback, kills even a trapping callback on timeout/cancel/owner death,
and observes its DOWN before reporting its result. Cancellation waits for that
callback result before invoking adapter.cancel, preventing overlap. Callback
references and execution generations fence stale results; immutable adapter,
session, generation, owner and execution identity fields fence swapped handles.
Observations remain ordered across batches; model completion never implies OS
exit. On process/capture terminal observations, bounded adapter reconciliation
supplies ownership evidence. Returned ownership must identify the retained handle.
Timeout, refusal and mismatched ownership stay unknown; worker/callback death
never substitutes for an external-process stop result.

Hard and idle timers retain handles and unique tokens in addition to generation.
Only nonempty observations reset idle; hard never resets. Old same-generation
idle messages cannot cancel a later activity window. Temporary child specs and
an empty new DynamicSupervisor ensure no reconstruction/relaunch after restart.
Worker status and crash formatting exclude prepared inputs, callback values and
opaque handles. Events carry observations and a terminal ownership/reason to the
fixed submitting caller; cancellation acknowledgments are only :cancelling.

The fake now has an independent stable-owner guardian that kills/reaps its
trapping BEAM runner on owner death, including when start spawned the runner but
its callback then blocked. Additional test-only block/probe controls support
trapping start/observe/cancel callbacks. This establishes fixture ownership only;
a real OS launcher must supply its own tested process-group/owner-death contract.

The additional thirteen supervisor tests cover nonzero OS exit after model completion,
independent hard/idle limits, stale same-generation timers and callback results,
caller death, start-spawn-then-block timeout, abrupt worker death with a trapping
callback, cancellation sequencing and uncertainty, swapped identities, capture
incompleteness, and no supervisor restart relaunch. Initial scoped Docker run:
21 tests total, zero failures, format and warnings-as-errors compilation passed.
Log: `/tmp/recurse-execution-supervisor-tests.log`. No real CLI, provider, process
group or canonical artifact admission is claimed by this fixture validation.

Primary review identified that a cleanup deadline during terminal reconciliation
could replace the previously observed exit/capture reason. Worker now preserves
both as `%{observation: terminal_reason, cleanup: trigger}`. A blocked-reconcile
plus blocked-cancel regression retains exit code 7 and capture_incomplete while
reporting unknown cleanup. Fake test teardown observes death directly to tolerate
its new owner guardian independently killing the runner when the test owner exits.

Independent review found an actual overflow path: a callback timeout larger than
Erlang's supported finite receive range could crash its guardian after spawning a
trapping callback. All Worker timer budgets and Callback.start now require
1..4_294_967_295 before spawning; guardian callback cleanup also runs in try/after.
The exact 4_294_967_296 regression proves rejection with no callback/runner start.
An unexpected guardian DOWN now terminates unknown instead of leaving a cancelled
worker in cancelling_wait. A suspended-guardian/injected-DOWN race verifies this
state transition; the real guardian is then resumed and its owner-death cleanup
is observed. This does not claim cleanup after externally force-killing the guardian.
Latest scoped run: 21 tests, zero failures; format and warnings-as-errors passed.
