# STR-273 preparatory prototype — BLOCKED on STR-312 / #1330

This directory is disconnected from production. The native File-only preparation
hook described below is integrated into restore; it does not implement suspended
sandboxes, advertise a capability, provide a UFFD page server, or complete #1252.
STR-313 idle policy is related work, not the hard prerequisite. Shared wire
schemas are left for coordination with the parent session; wire 64 is reserved
for GuestConfig.

## Reproduce safe checks

Run from the repository root on Linux with C headers and Python 3:

```sh
cc -Wall -Wextra -Werror prototypes/uffd-restore/probe.c -o /tmp/str-273-probe
/tmp/str-273-probe
python3 -m unittest discover -s prototypes/uffd-restore -v
```

The probe only opens a UFFD and negotiates its API if creation works. It never
registers guest memory, changes privileges, sysctls, seccomp, device permissions,
or a deployment. Its result cannot establish restore support. The Python model
uses digest-verified immutable bytes and separate private dirty-page dictionaries;
it tests bounds, trust mismatch, isolation, queue exhaustion, deadlines,
cancellation and fallback. Its backend selection is an illustrative contract,
not an agent health check. A production proof must be a scoped, expiring evidence
record, not a caller-supplied boolean. The model does not prove OS isolation,
on-disk immutability, physical sharing, dirty tracking, UFFD behavior or PSS.

## Evidence from this cloud session, 2026-10-02

Checkout: `a10e1c8fe0e998ebcddbf3ce13b3ee97de9dda49` at `/workspace/strato`.
Shell and checkout provisioned successfully. Host reports Linux `6.18.44`,
x86_64. No `/dev/kvm`, `/dev/userfaultfd`, or Firecracker binary on PATH.
`/proc/sys/vm/unprivileged_userfaultfd` is absent. `/proc/self/status` reports
`CapEff: 0000000000000000`, `Seccomp: 2`, one seccomp filter.

```text
syscall flags=0x80800 errno=38 (Function not implemented)
syscall flags=0x80801 errno=38 (Function not implemented)
lazy_restore_healthy=false (no end-to-end restore proof)
Ran 7 tests in 0.001s — OK
```

ENOSYS does not distinguish absent kernel support from syscall filtering in this
container. No UFFD API features were negotiated, no microVM was restored, and
no benchmark or clean-page-sharing claim is supported. Ordinary restore is also
untestable here because KVM/Firecracker are absent. No security settings changed.

## Version and feature requirements to resolve

The checked-out guest kernel pin is **6.1.177**, SHA-256
`f6529bfe1a457adab69156fb7fa2232cc203eb63f5e46210f9953d6fc9f70a30`
(`sandbox-guest/kernel/LINUX_VERSION`). This is the guest kernel, not proof of
host UFFD support. No Firecracker binary release/checksum pin or supported host
kernel matrix was found in the checked-out install scripts/workflows. Test
fixtures use 1.13.1; that is not a deployment pin. Architecture documentation
references `task install-firecracker`, but no Taskfile exists in this checkout.
The exact approved Firecracker/jailer binaries and digests are missing inputs.

For a concrete source reference only, upstream Firecracker **v1.13.1**
[persist.rs](https://github.com/firecracker-microvm/firecracker/blob/v1.13.1/src/vmm/src/persist.rs)
uses snapshot format **8.0.0**, anonymous guest memory, missing-page registration,
`EVENT_REMOVE`, nonblocking and close-on-exec UFFD, and `user_mode_only(false)`.
It sends a descriptor via SCM_RIGHTS plus JSON region mappings over a Unix socket.
Region fields include host address, size, backing offset and page size; the legacy
`page_size_kib` field contains bytes in this reference. Recheck these details
against the approved binary source before activating the reference receiver.

The [kernel API documentation](https://docs.kernel.org/admin-guide/mm/userfaultfd.html)
requires negotiating UFFDIO_API features and per-range UFFDIO_REGISTER ioctl
masks. The syscall route for kernel faults requires CAP_SYS_PTRACE or
`vm.unprivileged_userfaultfd=1`; `/dev/userfaultfd` access uses filesystem
permissions. User-mode-only success would not prove this Firecracker path.
No such privilege or permission changes are authorized in this task.

Retain default Firecracker seccomp. Verify the approved architecture-specific
filter permits its actual userfaultfd/device creation, ioctl, connect and sendmsg
path. The separate handler needs a reviewed minimal filter for recvmsg, peer
credentials, poll/read, UFFDIO_COPY/ZEROPAGE, backing reads and cancellation;
this session has neither audited nor changed those filters. Require negotiated
EVENT_REMOVE; disable balloon/hugepages in initial disposable tests until their
remove/zeroing and feature semantics are covered. Hugepage snapshots cannot
assume File fallback works (the reference rejects hugetlbfs File restore).

Retain existing exact Firecracker version, architecture, guest protocol, device
layout and CPU-template compatibility gates. A matching CPU template is not a
universal CPU portability promise; require host feature compatibility or the
existing exact CPU fallback, plus an actual restore. Snapshot and CPU metadata
must be bound to the same digest manifest as memory, disk and vmstate.

## Proposed boundary after STR-312 is available

STR-312 owns durable checkpoint verification, generation/activity races,
stop/destroy, quota release, resume admission and reconnect recovery. The memory
backend should plug into its fresh-VMM restore step and return an owned lease:
selected backend, artifact identity, handler identity, cancellation and health.
It must not own desired status, stop policy, quota, or a parallel resume path.

1. Pin and verify an immutable base manifest before starting the handler. Its
   key binds memory digest/size/layout, vmstate/disk digests, Firecracker binary
   digest, snapshot format, architecture, CPU template/features, guest protocol
   and an explicit trusted snapshot class. Refuse unknown or mismatched classes.
   Never use a workload checkpoint containing secrets or guest identity as a
   broadly shared golden image. Network/identity/device state remain private.
2. Publish digest-addressed memory through staging, verification, fsync and
   atomic rename; pin read-only open descriptors for a lease, reject symlink
   substitution and digest mismatch, and prohibit mutation while pinned. A name
   containing a digest alone does not establish immutable contents.
3. One supervised handler per sandbox initially. Its private delta is keyed by
   sandbox ID, checkpoint digest and generation, with no cross-session lookup.
   KVM dirty logging/checkpoint capture must produce the delta; missing-page
   handling alone does not observe subsequent guest writes. Revoke deltas and
   descriptors on cancellation and never reuse stale generations.
4. Bind a private socket in the existing jail; validate SO_PEERCRED against the
   owned VMM identity and receive exactly one descriptor. Bound handshake bytes,
   region count, total bytes, offsets, page alignment and overlapping address
   ranges before accepting events. Never use a fault address as a file path.
5. Start with queue capacity 64, handshake deadline 5s, fault deadline 1s and
   restore deadline 30s as provisional disposable-test bounds. Tune from live
   evidence. A separate watchdog must interrupt blocked reads/copies and kill
   only the owned VMM/handler using retained process identity. A model deadline
   check is not a watchdog. Report queue depth, faults, copy latency, timeouts,
   bytes read, handler CPU, failure and backend-selection reason.
6. Before resume, failed preparation may choose a verified ordinary full File
   restore in a fresh VMM. After resume, handler failure must fail that sandbox;
   restarting from an older checkpoint needs explicit lifecycle semantics.
   Never swap memory backends in a running VMM or label fallback as lazy.
7. On agent restart, default to File unless a durable lease and checkpoint can
   be reverified; reap owned orphan handlers without PID-reuse hazards. Evict
   only unpinned bases. Account base cache, private deltas and staging bytes
   separately; reserve disk for verification and bound total cache bytes.

## Integration update against STR-312 draft #1447

Integrated final STR-312 head `c57da019760db5af37b428087e3c775ccacef419`.
`restoreSandboxArchive` now calls a cancellation-aware memory preparation step
in both jailed and unjailed branches, after staging and before snapshot/load.
The result is structurally File-only with an explicit disabled reason. There is
no UFFD constructor, configuration switch or advertised capability to accidentally
enable a partial backend. STR-312 retains checkpoint, admission, generation,
resume, process teardown, deadlines, cancellation, journal, identity, retention
and quota ownership. Wake/restore binds expectedGeneration before load awaits,
then validates before durable resuming and the resume RPC. Superseding stop/delete
prevents resume; post-destruction recovery stays within the original generation.
Queued-restore retry and both fleet/suspension migration catalog round trips are
preserved from the dependency. Wire version remains 68.

`SandboxLazyMemoryPages` adds a native Swift page-source contract with a copied,
digest-verified immutable base, explicit trust class, bounded private delta,
checked page offsets and cancellation. It is currently isolated from guest
memory. It does not track guest writes, persist artifacts, handle UFFD events,
or prove physical sharing. Swift tests cover private data, digest/trust/bounds,
delta exhaustion, cancellation and production File fallback.

STR-312 now adds opt-in desired/observed Suspended evidence, control-plane
quota/storage readmission and exec wake at owner-allocated wire version 68.
Its API/control-plane implementation removes those missing-code blockers; its
real checkpoint/destroy/restore and continuity acceptance remain unproven here.
STR-273 owns no shared allocation and preserves the dependency's version 68.
Backend implementation
now has the isolated v1.13.1-reference descriptor/region receiver below, but
still needs approved-binary validation, a seccomp-reviewed retained-process
watchdog adapter, actual dirty capture, scoped live proof and
lifecycle cleanup integration. Local supervision, durable artifacts and negative
proof logic are described below. The environment limitations above remain.

## Additional kernel-independent implementation

`SandboxUffdTransport` and the local `CSandboxUFFD` shim implement a connected
Unix-socket receiver for the upstream **v1.13.1 reference protocol**, not a
verified Strato deployment pin. Exact SO_PEERCRED checks, atomically CLOEXEC
SCM_RIGHTS receipt, exactly one descriptor, bounded fragmented JSON, checked
4 KiB mappings and descriptor type/nonblocking checks precede readiness. The
shim reads Linux UAPI events and issues UFFDIO_COPY; EEXIST and EAGAIN are
explicit results. REMOVE, other lifecycle events, WP/minor faults and unsupported
layouts fail closed. This prototype requires no ballooning and no huge pages.
It must not be enabled for snapshots without verified matching metadata.

Eventfd cancellation wakes pollers. Each operation pins descriptor duplicates
and the lease bounds concurrent operations, preventing close/reuse across
leases. Cancellation cannot interrupt an ioctl already in flight and is **not**
process-death proof: STR-312 must retain ownership until outstanding work and
owned-process teardown are proven. A dedicated killable helper/watchdog adapter,
private socket binding/ownership, dirty capture and live evidence runner remain
unimplemented. Production restore is still structurally File-only and never
constructs this transport or advertises UFFD capability.

Seven transport tests use actual local Unix sockets, peer credentials,
SCM_RIGHTS, cancellation eventfds and a negative ioctl on `/dev/null`. Raw
32-byte Linux UAPI event fixtures test decoding, short reads, idle timeout and
cancellation; they **are not** valid UFFD descriptors or kernel fault evidence.
Tests reject wrong peer/type, absent/excess/truncated/extra descriptors, malformed
or overflowing mappings, incomplete messages, timeout and cancellation. No
successful UFFDIO_COPY, fault handling, snapshot restore or sharing is claimed.


`SandboxPageServerSupervisor` owns a single transport lease. It bounds pending
faults (including the active fault), serializes service, runs transport work
outside its actor, and applies independent handshake/fault deadlines. Overflow,
handler exit, bad response, invalid fault, and cancellation fail only that
lease, resume every waiter once, and revoke its transport. Late results cannot
make a failed lease healthy. Metrics include admission, service, high-water,
failures, deadlines, overflow, bytes served and wait durations. The adapter's
`stop` callback must be nonblocking and close owned descriptors; revocation is
not process-death evidence. STR-312 must retain resources until its teardown
proof completes. No production UFFD adapter is installed.

`SandboxLazyMemoryStore` uses an exclusively locked, existing private directory
and pinned directory descriptors; it rejects symlink traversal, hard-linked
payloads, unbounded metadata and mismatched digests. Base keys hash the memory
manifest, including trust and compatibility class. Delta keys hash a manifest
bound to sandbox, checkpoint, generation, base and per-page digests. Files are
created read-only to other opens, flushed, and published by a staged directory
rename followed by parent fsync. Existing keys are verified rather than replaced.
Returned page sources copy verified data; a pathname or read-only mode alone
is not an immutable-source guarantee against the host owner.

Disk bounds account base, private delta and unpublished staging bytes separately.
Unique pin tokens prevent a stale release from releasing another lease. Durable
deltas keep their base unevictable. Restart discards incomplete staging only;
committed data must reverify with the exact identity and class. Proofs and live
transport leases are not persisted/adopted. This implementation uses bounded
in-memory buffers (64 MiB store default, configurable up to 1 GiB), 4 KiB pages
and up to 4096 private pages per delta; a large-snapshot streaming adapter is
still needed before production use. It does not allocate or release workload
quota independently of STR-312.

The candidate capability evaluator rejects absent/fixture evidence, changed
kernel boot or agent-session scope, mismatched binary/isolation/snapshot/trust
scope, invalid digests, expired/future evidence, lifetimes over one hour and
missing checks. All kernel-fault API, EVENT_REMOVE, registered copy, peer/layout,
actual load/guest read/private write, sharing/PSS, crash isolation, cancellation,
File fallback and restart checks are required. This evaluates a receipt's
structure; it is not receipt authenticity or a live runner. Production remains
File-only even for a synthetically complete candidate. The future approved live
runner must generate and retain the actual evidence behind the digest.

A disposable `/bin/sleep` two-child test demonstrates local child exit/revocation
and cleanup through the existing ProcessRunner: one child exit does not stop the
other. That is not PID-safe production UFFD/VMM supervision, peer validation,
actual kernel fault handling or guest isolation evidence. Production must use
retained process identity and STR-312's teardown protocol, rather than adopt or
kill a recorded PID after restart.

The remaining live boundary is an approved Firecracker-specific adapter:
receive/validate its SCM_RIGHTS UFFD and memory mappings under the approved jail
and seccomp; resolve kernel page faults with the negotiated ioctls; integrate
actual dirty tracking, remove/zero events and stop/exit proof; and demonstrate
correct restore and clean-page sharing. The syscall probe cannot enter that
boundary in this environment. No privilege changes are needed for the completed
local components, and none were made.

## Remaining proofs and acceptance blockers

The upstream [loading guide](https://github.com/firecracker-microvm/firecracker/blob/v1.13.1/docs/snapshotting/handling-page-faults-on-snapshot-resume.md)
describes copying base pages into anonymous guest memory. **UFFDIO_COPY does
not establish shared clean guest pages.** A shared source page cache and laziness
alone cannot meet #1252's physical-sharing/PSS acceptance. That needs a separately
validated mapping strategy supported by the approved VMM, without weakening
isolation or changing host security settings. Do not infer it from this model.

After approved disposable KVM/UFFD fixtures and STR-312 exist, exercise actual
snapshot/load with the default jail/seccomp, guest reads and writes, then inject
handler exit/stall during load and run, queue overflow, bad descriptor/mappings,
cancellation, base corruption, wrong trust/CPU class, restart and ordinary File
fallback. Include secret/identity/device-state isolation across two guests and
prove a crash affects only its lease. Measure PSS rather than summed RSS and
separate source cache from guest pages. Only then run disposable 1/10/100 restore
benchmarks with latency p50/p95/p99, fault latency, handler CPU, disk reads and
host PSS; cap admission/resources before increasing concurrency.

Missing today: STR-312 live lifecycle acceptance, approved Firecracker/jailer pin
and host matrix, permitted KVM/UFFD fixture, compatible verified snapshots, end-to-end
restore proof, physical-sharing strategy/proof and fault-injection benchmarks.
STR-273 remains blocked and incomplete. The draft is reconciled onto the final
STR-312 `c57da019` boundary; activation remains blocked on actual disposable
KVM/UFFD lifecycle acceptance and the other live proofs above.

Validation of the combined draft against final STR-312 head `c57da019`: the full
Linux x86_64 Swift 6.4.0 agent suite passed all five products
(929 + 348 + 70 + 45 + 531 = **1923 tests**, including seven transport fixtures and the dependency regression additions). The full shared suite passed
**274 tests**. The current-schema baseline suite passed **10 tests** against
disposable local PostgreSQL 15, including the preserved fleet and suspension
revert/reapply catalog round trips; its container was removed afterwards.
Seven Python tests, strict Swift formatting, whitespace checks
and C probe/transport compilation passed. Both UFFD syscall variants still returned ENOSYS.
The initially timing-sensitive two-child fixture now triggers exit only after
admission; the complete final runs passed. These local tests do not establish
actual Firecracker restore, guest-sharing/PSS or benchmark acceptance.
