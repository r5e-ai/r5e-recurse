# Managed Git push

The runtime exposes a typed push command. This is a pre-act policy boundary for the managed workflow; forge-wide enforcement and freight membership are milestone two.

## Admission

Admit `gateway.r5e.io/v1alpha1/ToolCall` with `tool: git.push`, the session span and inline structured `args`:

- `operationId`: semantic command identity.
- `repoId`: configured immutable repository identity, resolved to an allowed remote URL by the runtime. No arbitrary URL from model text.
- `destinationRef`: fully qualified `refs/heads/...` branch.
- `revision`: exact commit OID, plus `objectFormat` (`sha1` or `sha256`). Resolve moving local names before admission.
- `expectedRemoteRevision`: exact observed prior OID or null for an absent branch.
- `artifactRef` and `decisionRef`: exact work/acceptance evidence for this workflow.

The runtime creates a separate operator-authorized action session for the push, with a fresh effective Badge and binding to the accepted artifact/decision. Its harness is `runtime-git`, not a claimed model provider. The command cites the originating producer/review evidence, but the ToolCall actor is this action-session key under its Badge. Never revive a closed producer route or silently renew an expired producer credential. Record action-session closure and an operational outcome assessment as runtime observations, not invented model reflection. Policy uses the structured arguments, session authority and configured destinations and requires `args.revision == Artifact.repoAssociation.oid`, matching repo ID and object format as well. Artifact and accepting Decision refs resolve to the exact admitted versions. Initial rules reject main and any other configured protected branch, tags, deletion, wildcard/multi-ref pushes, force, arbitrary URLs and missing required artifact/decision evidence. A refused request gets its canonical denial and no dispatch. Freight membership is not yet required.

## Dispatch

Push from a **runtime-owned bare repository**, never from the agent-writable checkout. Under a per-operation lock, fetch the exact admitted OID from the workspace into that bare repository using a local transport, then verify the object type/OID and its accepted artifact association. Do not invoke Git in the workspace to inherit its config. Treat the workspace as untrusted object input; force the expected local upload-pack program and prohibit hooks/recursive submodule fetches and unexpected protocols during import. Validate source paths and keep the destination bare repository outside agent writing directories.

Use an explicitly constructed environment with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`; clear inherited Git environment/config injection such as `GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS`, alternate git-dir/work-tree and SSH command overrides. The bare repository has runtime-controlled allowlisted configuration, disabled hooks/fsmonitor and credential helpers, no URL rewrites, no recursive submodule pushes, and no checkout/filter execution. Inject the runtime's selected SSH command/credential intentionally after sanitization. Assert the effective remote destination matches the configured identity.

Writer workspaces receive a dead local `pushurl` and no credential helper. Their isolated harness environment does not inherit the runtime push credential. Runtime pushes use a distinct repository-scoped deploy key; record only its public identifier. On a same-user host these measures reduce accidental bypass, not hostile secret access; direct pushes with another credential are outside the governed path and may be distinguishable in forge audit only where the forge records credential identity.

Recheck expected remote state, then dispatch a non-shell argument vector using the exact admitted OID-to-ref refspec. No moving local branch supplies the pushed revision.

Default dispatch is a normal non-forced single-ref push. The remote may change after preflight; a non-fast-forward refusal is a legitimate failed result. This initial contract does not claim compare-and-swap remote updates or a lease implemented by the preflight check. If remote CAS becomes required, add an explicitly tested server/protocol mechanism rather than claiming ordinary push supplies it. The exact admitted OID/ref binding remains mandatory in either case.

Record `ActionResult` with ToolCall ref, operation ID, exit status, bounded stdout/stderr refs and observed remote OID. ToolCall admission does not prove the remote changed; a command exit alone does not establish every remote observation.

## Recovery and limits

Crash after admission or loss of push response leaves the action uncertain. Inspect the canonical command and query the remote. An observed matching revision is evidence of current remote state, not proof of which actor moved it. Preserve that distinction and require a recorded recovery decision before any repeat dispatch. Never automatically issue another push because the local acknowledgment was lost.

Managed agents receive no direct push tool and use harness restrictions where supported. Their ability to invoke arbitrary host commands is a declared cooperative-profile limit. This runtime contract does not claim to prevent a malicious process using other credentials or network paths. Accidental direct push attempts through exposed managed tools must be refused and redirected to this command. Strong non-bypass enforcement belongs to the containment profile.

## Tests

Use a disposable bare remote: allowed branch; main refusal with unchanged remote; changed local branch after admission; wrong repo alias/URL rewrite; invalid OID; already-moved remote; force/deletion/multi-ref rejection; hook/submodule side effects disabled; successful dispatch with lost response; crash before dispatch; duplicate ID with different args. Observe both canonical records and actual remote refs. Tests never use a public project remote. Add hostile workspace git-config fixtures (hooks, fsmonitor, sshCommand, helper, URL rewrite and environment injection) that write markers: no marker may be created by runtime import/push. Assert use of the bare repo/distinct deploy-key identity and reject an OID differing from the accepted Artifact.

Merges occur on the forge outside this loop. Admitted branch push is not governed merge; merge/forge enforcement remains milestone two.
