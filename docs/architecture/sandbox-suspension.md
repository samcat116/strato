# Suspended sandboxes: STR-312

The guarded lifecycle is wired end to end behind explicit opt-in. `POST stop`
with `{"suspend": true}` requests durable suspension; an empty stop request keeps
its existing pause behavior. `POST snapshots` with `stop=true,suspend=true` first
captures the user-owned snapshot, then suspends the parent on its shared lane.
Default idle policy remains disabled pending real VM acceptance.

Wire version **68** adds desired and observed `Suspended`, a total internal
checkpoint storage budget, an optional capture dependency and a retained
checkpoint ID. Versions 64–67 are reserved for the parent's coordinated guest
configuration, density, headroom and resource-class changes. Those branches must
be integrated preserving the final exact version handshake.

The control plane reserves checkpoint storage using the owning agent's actual
rootfs/config plus guest-memory estimate. It retains CPU/memory until a settled,
verified, VMM-destroyed fact matches the current desired generation and admitted
budget. Sandbox count, placement, UID/network identity and checkpoint storage
remain reserved. Start, explicit restore and exec wake transactionally readmit
compute under the shared quota locks before writing running intent. Concurrent
wakes cannot exceed the same quota. Stale reports cannot undo a newer reservation.

Exec on a suspended sandbox returns the existing `202` accepted wake mutation;
no exec session is minted during restore. Retry after convergence. The frontend
waits at most 30 seconds, refusing superseded/degraded generations before making
the session request. The runtime separately guards pending handshakes before
awaiting and established sessions through their lifetime.

Retained checkpoint evidence and restore duration are exposed in sandbox detail.
Control-plane restart/failover reads the same durable database ledger; no local
replica owns the reservation. Local checkpoint state remains pinned to its agent.
If journal/artifacts are unavailable or a resumed guest may have progressed,
recovery blocks instead of silently replaying old memory or creating fresh OCI
state. Cross-host checkpoint transport is not provided by this local lifecycle.

## Implemented checkpoint foundation

New local sandbox checkpoints publish `checkpoint-integrity.json` after capturing
memory/vmstate and copying rootfs/config while the guest is paused. It binds the
sandbox ID, snapshot ID, guest identity nonce, Firecracker version, guest protocol,
and sizes/SHA-256 of all four artifacts. Hashing uses bounded buffers off the
runtime actor. Files are opened relative to a pinned archive directory with
`O_NOFOLLOW`; nonregular files and hard links are refused. Artifacts are fsynced
before an exclusive temporary manifest is fsynced and renamed; the archive and its
two parent directories are fsynced before publication succeeds.

Restore-in-place verifies this evidence when present before draining streams or
destroying the existing VMM. Invalid evidence cannot downgrade to the legacy
path. Existing archives without a sidecar retain their prior restore behavior;
exported copies continue to use control-plane-hashed download descriptors. The
sidecar is local evidence and is not an exported artifact or a trust signature.

VMM teardown errors now block replacement. A missing client registry entry permits
a retry only after the existing process/jail identity checks prove absence.

These checks establish local integrity and flush ordering, **not restorable
machine state**. They do not pin an immutable filesystem lease across restore,
prove Firecracker/kernel/CPU compatibility, simulate power loss, or validate an
actual snapshot/load. They cannot authorize destroying the only running copy.

## Lifecycle and generation contract

Agent-local interfaces:

```swift
noteSandboxIntent(sandboxId: String, generation: Int64, desiredRunning: Bool)
suspendSandbox(sandboxId: String, generation: Int64, automatic: Bool)
suspensionRecord(sandboxId: String) -> SandboxSuspensionRecord?
suspensionStorageEstimate(sandboxId: String) -> Int64
resumeSuspension(sandboxId: String, networkAttachments: [ResolvedNetworkAttachment])
```

Each method is async; operations and record reads throw on failure. STR-313 must
enter through `Agent.sandboxReconcileSuspend(_:automatic:)`, which reserves host
headroom for the extra validation VMM and checkpoint staging. It must not call
the driver directly. Runtime admission registers pending exec handshakes before
their first await; established user exec sessions refuse suspension. Internal log
followers drain without counting as user activity. The generation/activity commit
is synchronous. Activity before destruction aborts capture and resumes the
original; activity/new running intent after destruction requests restore.

The runtime journals capturing/verified/destroying/suspended/restoring/resuming/
resumed before side effects. It validates a real jailed shadow VMM through
`PUT /snapshot/load` with `resume_vm: false`, checks Paused, and proves shadow
teardown before original destruction. Shadow IDs/UID records reuse the existing
warm-template crash sweep. A distinct jail/vsock filesystem prevents a duplicate
guest identity channel; paused vCPUs do not execute the workload. Networked shadow
validation remaps to an isolated TAP in the shadow's own namespace, attached to
nothing; it never contends for the original single-queue TAP. Networked validation
therefore requires Firecracker's existing network-overrides gate. This path
still needs real Firecracker/KVM evidence; fixture tests do not prove it.

Restore admission defaults to two per agent (validated range 1...32), with a
1200-second default deadline (validated range 5...1200). Admission includes shadow
validation. Timeout cancels and waits for side effects to unwind; permits are held
through cleanup, so an unresponsive operation cannot race a retry. This is not a
hard bound on uninterruptible kernel I/O. Internal restore loads paused, commits
`resuming`, then resumes and verifies identity. A failure after that commit retains
the guest and memory reservation instead of replaying an older checkpoint.

Host admission reserves both capture and shadow filesystem copies, plus the extra
proof VMM. File restore reserves the archive and fresh jail copy through restart.
Host manifests retain spec/UID, release guest CPU/RAM only on verified suspended
facts, and retain checkpoint storage. Restore persists the full reservation before
spawning. Failed reservation writes retain the admission claim for retry.
Each validation VMM publishes its own durable CPU/RAM/disk reservation and restore
permit before spawning. Failed destruction or process inventory keeps those
owners across agent restart; cleanup releases them only after process death and
artifact removal are proved. Unknown proof inventory advertises no available
capacity, including when the sandbox runtime is disabled. Recovery skips active
validation owners and retries abandoned proofs separately from warm-template
builds.
Internal artifacts live under `<sandbox>/hibernation/<id>`; retiring a previous
internally owned checkpoint cannot delete a user snapshot. Cold recreation is
refused when a suspension journal represents the only copy or a guest that may
have advanced past the checkpoint.

STR-313 supplies eligibility but must request the desired `Suspended` generation
and admitted storage budget through the control plane before actuation. A
running goal cannot be treated as already suspended. STR-273 integrates after
fresh VMM staging and before snapshot/load; it must use this lifecycle's permit,
generation fence, cancellation and quota ownership rather than a separate resume
route. Backend failures before resume may fall back to verified File restore;
after resume, the guest may have advanced and must not be rewound silently.

## Validation blocker in this selected environment

The workspace has Swift 6.4.0 and can run agent tests, but `/dev/kvm` is absent and
Firecracker is not installed on PATH. No real capture/load, VMM RSS/cgroup floor,
process/network continuity, failover lifecycle, restore herd load test, or latency
percentiles have been demonstrated here. No live infrastructure, credentials,
security settings, merge, or deployment are changed. The lifecycle must
be verified on an authorized disposable KVM fixture before this
issue can be completed or either dependent feature enabled.

Journal-backed wake and explicit restore bind the requested running generation before the first load await and recheck it immediately before the durable resuming commit and resume RPC. A newer stop or delete leaves the replacement paused; activity recovery after committed destruction is permitted only for the original suspension generation.

## Optional automatic guest fence (STR-313 integration seam)

The STR-312 lifecycle follow-up adds the optional journaled transport seam. STR-313 supplies its wire 69 DTOs, guest-control v5 monitor, durable CP admission and production adapter. Both CP and agent automatic-policy gates default off. Default guest builds and published/bootstrap v4 contracts remain v4; only an opt-in build with a working trusted monitor advertises v5. Manual requests retain the existing path. Only a no-NIC, already-running, negotiated-v5 guest can use the fenced automatic entry point.

Policy enters through `Agent.sandboxReconcileSuspend(_:automatic:fence:)` with `automatic: true`, a CP-admitted Suspended desired generation and matching fence, retaining existing host admission. `SandboxRuntimeService.suspendSandbox(sandboxId:fence:)` accepts `SandboxAutomaticSuspensionFence` with `operationId`, `generation`, `activityRevision`, `admissionToken` and `guestProtocolVersion`. Its journal envelope binds the sandbox/checkpoint IDs and guest identity nonce. The transport methods are `prepare(context) -> UUID`, `query(context) -> SandboxGuestFenceStatus`, `validateAdmission(context)` and `release(context)`. Guest status is absent, prepared(token), or released. The adapter must make guest operations idempotent by operation ID, retain that state through checkpoint/restore and prohibit reuse of a released operation.

The lifecycle persists prepare-pending before querying or freezing the guest. A lost prepare response is recovered by querying the same operation, without a second freeze. The prepared token is journaled before capture. Guest prepare must atomically close admission, quiesce and freeze workloads while keeping the control service available. After capture and shadow verification, final admission validation contacts the durable CP token only: the VMM is paused and cannot answer guest queries. The synchronous host generation/activity check remains immediately before the destruction commit. CP admissions must invalidate that durable token and request cancellation/wake; a sampled activity revision is insufficient.

Rollback verifies the surviving original's identity and releases the guest fence before deleting the candidate journal. Verified restore releases the fence before committing resumed or admitting exec. Release-pending is durable before its RPC, and the journal remains blocked until query confirms released. A restart retries the same operation even when the host never received its prepare token. Restoring an older checkpoint repeats release even if an earlier guest copy acknowledged it. Prepare, final CP validation and release each have a 20-second stage budget; failed release retains recovery evidence and blocks exec. Missing guest or adapter never implies successful thaw or authorizes cold recreation. Partial artifact accounting remains conservative until its owner completes cleanup.

The existing real VM acceptance gap still applies. Transport/journal fixture tests establish ordering and recovery contracts; they do not prove guest freezing, memory reclamation, or automatic-policy safety. No automatic activation, guest release publication, live policy or deployment is included.
