# Suspended sandboxes: STR-312 implementation boundary

STR-312 / [#1330](https://github.com/samcat116/strato/issues/1330) is **incomplete**.
The local runtime now implements guarded checkpoint, paused fresh-VMM load
validation, destruction, and restore/recovery APIs. These are not yet activated
by stop or exposed as a coordinated wire/API contract; control-plane quota and
operation integration remain unfinished. No capability is advertised and
STR-273/STR-313 remain blocked. Stop still pauses the VMM. This document records the integration contract so policy
and memory-backend work do not establish independent lifecycle owners.

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

## Proposed lifecycle and generation contract

Implemented agent-local interfaces (no wire version allocated):

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

Host manifests retain spec/UID, release guest CPU/RAM only on verified suspended
facts, and retain checkpoint storage. Restore persists the full reservation before
spawning. Failed reservation writes retain the admission claim for retry.
Internal artifacts live under `<sandbox>/hibernation/<id>`; retiring a previous
internally owned checkpoint cannot delete a user snapshot. Cold recreation is
refused when a suspension journal represents the only copy or a guest that may
have advanced past the checkpoint.

The remaining shared/control-plane integration is design guidance:

* Add desired and observed `Suspended` for a checkpoint-backed sandbox with
  confirmed VMM absence. Explicit stop of a booted workload selects the suspended
  goal; legacy/unstarted `Stopped` remains distinguishable and is not evidence of
  reclamation. This avoids treating a paused intermediate state as already
  satisfying suspension, including checkpoint-and-stop and restart recovery. Preserve
  the existing `Exited` one-shot semantics. Coordinate any shared contract and
  wire bump with the parent: guestConfig PR #1436 owns v64, and this branch
  allocates no version.
* The owning sandbox generation guards every transition. Persist the checkpoint
  ID, capture generation, activity epoch, guest identity, network device shape,
  jail UID, compatibility evidence, and lifecycle phase before destructive work.
  Lifecycle phases are capturing, validating, ready-to-destroy, suspended, and
  restoring. Phase advancement must be durable, idempotent, and generation
  checked; observations never acknowledge the wrong generation.
* STR-313 supplies eligibility and activity knowledge. STR-312 owns a per-sandbox
  admission guard shared by policy, exec/session admission, snapshot, stop,
  restore, and delete. Activity invalidates an in-flight capture before the
  destruction commit; if destruction already committed, it requests one
  serialized verified restore. Pending commands, live sessions, unknown activity,
  unsupported backends, and unavailable proofs cannot enter suspension.
* Capture into a distinct internally owned artifact. Flush and verify integrity,
  then establish a real restorable proof using the approved VMM and compatible
  disposable fixture. Recheck generation and activity immediately before the
  destruction commit. Failure or cancellation preserves/resumes the original
  guest. No mock, digest, filename, or version string constitutes that proof.
* Report suspended only after retained process identity confirms VMM exit and
  host-memory accounting confirms reclamation. Keep the network allocation,
  sandbox identity, count, checkpoint bytes, and jail UID reserved. Never use
  deletion cleanup to release a suspended sandbox's identity.
* Start and supported guest operations use the same restore admission path:
  transactional quota readmission, host-headroom admission (STR-265), a bounded
  agent restore permit, fresh VMM staging, full snapshot/load, identity handshake,
  then running observation. Preserve filesystem, processes, network allocation,
  guest nonce, and log sequence semantics. A failed restore retains the durable
  checkpoint and cannot fall back to a cold launch or roll back an already
  resumed workload silently.
* STR-273 plugs into fresh-VMM snapshot/load with an owned memory-backend lease.
  It owns neither stop policy, desired status, generation, quota, nor a second
  resume route. Backend failure before resume may select a verified full File
  restore; failure after resume requires an explicit failure verdict.

## Admission, recovery, and retention requirements still to implement

Restore permit count and timeout are agent configuration with bounded validation;
their defaults require real load evidence. Count active work through cancellation
and VMM cleanup, not merely through request return. Persist restore latency and
failure as workload conditions; publish disposable-load p50/p95/p99 results.

Quota accounting must retain memory while capture/destruction is incomplete,
release it only on verified suspension, and reacquire it in the same transaction
as desired-running admission. Concurrent starts sharing ancestor quotas must use
the existing quota locks. Desired-running but still suspended/restoring workloads
must count once, including during resync. Charge staging/checkpoint storage before
capture; preserve sandbox count and user-snapshot storage throughout. Agent host
reservations must follow the same durable facts instead of spec-only sizing.

Recovery must reverify checkpoint identity and compatibility before acknowledging
each persisted phase. Prefer adopting an original live VMM over restoring an older
copy; prove absence before replacement. A ready-to-destroy record with a live
original must recheck current intent/activity. A suspended record must never fall
through orphan `adoptionTargetGone` into cold recreation. An interrupted restore
must adopt and validate its owned replacement or retain its checkpoint for retry.
Control-plane failover must use PostgreSQL generations and artifact rows as truth;
Valkey coordination cannot authorize checkpoint deletion or quota release.

Internally owned checkpoints need separate ownership and retention from user
snapshots. Keep the latest resumable checkpoint until its replacement is verified
and durably referenced; retain it across failed restores. Delete superseded idle
artifacts only when no lifecycle/backend lease pins them. User-created snapshots
remain governed by their existing explicit retention/deletion contract.

## Validation blocker in this selected environment

The workspace has Swift 6.4.0 and can run agent tests, but `/dev/kvm` is absent and
Firecracker is not installed on PATH. No real capture/load, VMM RSS/cgroup floor,
process/network continuity, failover lifecycle, restore herd load test, or latency
percentiles have been demonstrated here. No live infrastructure, credentials,
security settings, merge, or deployment are changed. The remaining lifecycle must
be implemented and verified on an authorized disposable KVM fixture before this
issue can be completed or either dependent feature enabled.
