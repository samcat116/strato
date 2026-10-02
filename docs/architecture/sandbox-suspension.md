# Suspended sandboxes: STR-312 implementation boundary

STR-312 / [#1330](https://github.com/samcat116/strato/issues/1330) is **incomplete**.
The checkpoint integrity foundation below does not implement suspension, release
memory quotas, advertise a capability, or unblock STR-273/STR-313. Stop still
pauses the VMM. This document records the proposed integration contract so policy
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

The following is design guidance, not an implemented public API:

* Reuse desired `Stopped` for the explicit stop goal; add observed `Suspended`
  for a checkpoint-backed sandbox with confirmed VMM absence. A never-started
  `Stopped` sandbox remains distinguishable from a suspended workload. Preserve
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
