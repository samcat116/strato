import Foundation
import Libvirt
import NIOCore
import StratoShared
import Testing

@testable import StratoAgentCore

/// `LibvirtService` links a hypervisor SDK and therefore has no unit tests, so
/// everything it can decide without a daemon is decided here — and asserted
/// here. Each of these is silent when wrong: a mis-mapped domain state makes
/// the reconciler act on a fiction, a wrong bit in the undefine mask leaks
/// state for the life of the host, and an error translated into the wrong case
/// turns a retryable timeout into a permanent failure (or the reverse).
@Suite("libvirt domain vocabulary")
struct LibvirtDomainTests {

    // MARK: - Domain state

    @Test("Every virDomainState maps to the status the reconciler plans from")
    func mapsEveryState() {
        let expected: [LibvirtDomain.State: VMStatus] = [
            .noState: .unknown,
            .running: .running,
            // Blocked on I/O is still a live guest, not a stopped one.
            .blocked: .running,
            .paused: .paused,
            .shuttingDown: .shutdown,
            .shutoff: .shutdown,
            .crashed: .error,
            .pmSuspended: .paused,
        ]
        for state in LibvirtDomain.State.allCases {
            #expect(state.vmStatus == expected[state], "state \(state)")
        }
        #expect(LibvirtDomain.State.allCases.count == expected.count)
    }

    /// `SHUTOFF` is what a freshly defined domain sits in, and the create
    /// contract ends "exists, not running" — so this pairing is what lets a
    /// define alone satisfy `ReconcileStep.create` with none of the QEMU
    /// driver's `awaitingFirstStart` disambiguation.
    @Test("A defined-but-never-started domain satisfies a shutdown desired state")
    func freshlyDefinedDomainConverges() {
        let status = LibvirtDomain.State.shutoff.vmStatus
        #expect(DesiredVMStatus.shutdown.isSatisfied(by: status))
        #expect(Reconciler.statusSteps(desired: .shutdown, observed: status).isEmpty)
        #expect(Reconciler.statusSteps(desired: .running, observed: status) == [.boot])
    }

    @Test("An unrecognised state is unknown, never a guess")
    func unknownStateIsNotGuessed() {
        // The enum is append-only upstream, so a newer libvirt can report a
        // value this build has never heard of.
        #expect(LibvirtDomain.vmStatus(forRawState: 99) == .unknown)
        #expect(LibvirtDomain.vmStatus(forRawState: -1) == .unknown)
        #expect(LibvirtDomain.vmStatus(forRawState: 1) == .running)
    }

    @Test("Resource-holding is read the way a delete needs it: unknown and crashed both count")
    func resourceHoldingStates() {
        for state in [LibvirtDomain.State.running, .blocked, .paused, .pmSuspended, .shuttingDown, .crashed] {
            #expect(state.holdsResources, "state \(state)")
        }
        for state in [LibvirtDomain.State.shutoff, .noState] {
            #expect(!state.holdsResources, "state \(state)")
        }
        // The caller that asks is about to unlink a running guest's disk, so an
        // unreadable state must not read as "safe to remove".
        #expect(LibvirtDomain.holdsResources(rawState: 99))
        // `crashed` counts even though the document's `<on_crash>destroy</>`
        // means libvirt should never park a domain there: under `preserve` the
        // QEMU process is still alive, and that must not become a cross-file
        // dependency of "may I delete these disks".
        #expect(LibvirtDomain.holdsResources(rawState: 6))
    }

    /// The two predicates are deliberately not each other's negation, and this
    /// is the pairing that proves it: a boot must attempt the start on a state
    /// it cannot read, while a delete must keep its hands off the disks of one.
    @Test("Running-or-paused takes the opposite default, so an unreadable state never skips a boot")
    func runningOrPausedStates() {
        for state in [LibvirtDomain.State.running, .blocked, .paused, .pmSuspended, .shuttingDown] {
            #expect(state.isRunningOrPaused, "state \(state)")
        }
        for state in [LibvirtDomain.State.shutoff, .crashed, .noState] {
            #expect(!state.isRunningOrPaused, "state \(state)")
        }
        #expect(!LibvirtDomain.isRunningOrPaused(rawState: 99))
        #expect(LibvirtDomain.holdsResources(rawState: 99) != LibvirtDomain.isRunningOrPaused(rawState: 99))
    }

    // MARK: - Flags

    /// Pinned against `libvirt.h` rather than restated from the source: every
    /// one of these is a bitmask the daemon interprets, and a wrong bit fails
    /// silently rather than being rejected.
    @Test("Flag constants match libvirt's own values")
    func flagValues() {
        // VIR_DOMAIN_NONE / VIR_DOMAIN_SHUTDOWN_DEFAULT.
        #expect(LibvirtDomain.startFlags == 0)
        #expect(LibvirtDomain.shutdownFlags == 0)
        // VIR_DOMAIN_DESTROY_DEFAULT — SIGTERM, then SIGKILL. Asserting the
        // value alone would be worthless here, since `GRACEFUL` (1) is the
        // *weaker* behaviour despite the name: it is SIGTERM-only, and every
        // destroy this driver issues is an escalation that has to be able to
        // force. So the assertion is written as "not GRACEFUL".
        #expect(LibvirtDomain.destroyFlags == 0)
        #expect(LibvirtDomain.destroyFlags & 1 == 0, "VIR_DOMAIN_DESTROY_GRACEFUL cannot force a wedged guest down")
        // VIR_CONNECT_LIST_DOMAINS with no filter: persistent and transient,
        // running and not.
        #expect(LibvirtDomain.listAllDomains == 0)
    }

    @Test("The undefine mask covers every piece of state that outlives the domain")
    func undefineFlagsCoverEverything() {
        let flags = LibvirtDomain.undefineFlags
        // MANAGED_SAVE | SNAPSHOTS_METADATA | NVRAM | CHECKPOINTS_METADATA | TPM
        #expect(flags == 1 | 2 | 4 | 16 | 32)

        // Spelled out individually too, because the sum above would still pass
        // with two bits swapped.
        #expect(flags & 1 != 0, "VIR_DOMAIN_UNDEFINE_MANAGED_SAVE: libvirt refuses the undefine without it")
        #expect(flags & 2 != 0, "VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA")
        #expect(flags & 4 != 0, "VIR_DOMAIN_UNDEFINE_NVRAM")
        #expect(flags & 16 != 0, "VIR_DOMAIN_UNDEFINE_CHECKPOINTS_METADATA")
        // The one that is not redundant with removing the VM's directory:
        // libvirt keeps swtpm state under /var/lib/libvirt/swtpm/<uuid>.
        #expect(flags & 32 != 0, "VIR_DOMAIN_UNDEFINE_TPM: without it every TPM VM leaks its vTPM state")
        // KEEP_NVRAM (8) and KEEP_TPM (64) are the *opposites* of what a delete
        // wants and would each be rejected alongside their counterpart.
        #expect(flags & 8 == 0, "VIR_DOMAIN_UNDEFINE_KEEP_NVRAM must not be set")
        #expect(flags & 64 == 0, "VIR_DOMAIN_UNDEFINE_KEEP_TPM must not be set")
    }

    /// The domain document is written once and never rewritten, so normal
    /// device changes reach both definitions. Network detach uses the two
    /// individual bits in sequence to make a partial result replayable.
    @Test("Device flags distinguish live and persistent definitions")
    func deviceFlagsDistinguishDefinitions() {
        // VIR_DOMAIN_AFFECT_LIVE (1) | VIR_DOMAIN_AFFECT_CONFIG (2).
        #expect(LibvirtDomain.affectLive == 1)
        #expect(LibvirtDomain.affectLiveAndConfig == 1 | 2)
        #expect(LibvirtDomain.affectConfig == 2)
        #expect(
            LibvirtDomain.affectLive & 2 == 0,
            "the replayable live detach must not depend on matching persistent state")
        #expect(
            LibvirtDomain.affectLiveAndConfig & 2 != 0,
            "a live-only hot-plug is lost at the guest's next power cycle")
        #expect(
            LibvirtDomain.affectConfig & 1 == 0,
            "VIR_DOMAIN_AFFECT_LIVE against an inactive domain is VIR_ERR_OPERATION_INVALID")
        // VIR_DOMAIN_VCPU_MAXIMUM / VIR_DOMAIN_MEM_MAXIMUM, which share a bit
        // and are only legal alongside CONFIG.
        #expect(LibvirtDomain.affectMaximum == 4)
    }

    @Test("A running vCPU shrink is refused instead of becoming a config-only success")
    func runningVCPUShrinkIsNotAnOnlineResize() throws {
        #expect(
            try LibvirtDomain.vcpuResizeFlags(current: 2, target: 4, domainIsLive: true)
                == LibvirtDomain.affectLiveAndConfig)
        #expect(
            try LibvirtDomain.vcpuResizeFlags(current: 2, target: 1, domainIsLive: false)
                == LibvirtDomain.affectConfig)
        #expect(try LibvirtDomain.vcpuResizeFlags(current: 2, target: 2, domainIsLive: true) == nil)

        do {
            _ = try LibvirtDomain.vcpuResizeFlags(current: 2, target: 1, domainIsLive: true)
            Issue.record("expected a running shrink to be refused")
        } catch let error as HypervisorServiceError {
            guard case .notSupported(let reason) = error else {
                Issue.record("expected notSupported, got \(error)")
                return
            }
            #expect(reason.contains("stop the VM"))
            #expect(reason.contains("live vCPU unplug is not supported"))
        }
    }

    @Test("Checkpoint flags select a running revert and the completed job")
    func checkpointFlags() {
        // VIR_DOMAIN_SNAPSHOT_REVERT_RUNNING. Without it the revert leaves the
        // guest in whatever state the checkpoint recorded, while a restore's
        // post-condition is that the VM is running.
        #expect(LibvirtDomain.snapshotRevertRunning == 1)
        // VIR_DOMAIN_SNAPSHOT_REVERT_PAUSED (2) would do the opposite.
        #expect(LibvirtDomain.snapshotRevertRunning & 2 == 0)
        // VIR_DOMAIN_JOB_STATS_COMPLETED: without it a query after the job has
        // finished answers "no job" and the checkpoint's size is lost.
        #expect(LibvirtDomain.jobStatsCompleted == 1)
    }

    @Test("Guest observation asks the agent, not libvirt's own leases")
    func guestObservationFlags() {
        // VIR_DOMAIN_GUEST_INFO_HOSTNAME.
        #expect(LibvirtDomain.guestInfoHostname == 8)
        // VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT. `_SRC_LEASE` (0) reads
        // libvirt's own DHCP leases, which Strato does not run — the control
        // plane does IPAM — and `_SRC_ARP` (2) never sees IPv6.
        #expect(LibvirtDomain.interfaceAddressesFromAgent == 1)
    }

    @Test("A missing snapshot is distinguishable, because a delete reads it as success")
    func classifiesMissingSnapshot() {
        #expect(LibvirtFailure.isSnapshotMissing(daemonError(.noDomainSnapshot)))
        #expect(!LibvirtFailure.isSnapshotMissing(daemonError(.noDomain)))
        #expect(!LibvirtFailure.isSnapshotMissing(daemonError(.invalidDomainSnapshot)))
        #expect(!LibvirtFailure.isSnapshotMissing(LibvirtClientError(.connectionClosed)))
    }

    /// A guest with no agent installed is the normal case, not a fault — and
    /// laundering a genuinely broken daemon into "this guest is quiet" would
    /// hide it, so only the agent codes count.
    @Test("An unreachable guest agent is distinguishable from a broken daemon")
    func classifiesGuestAgentUnavailable() {
        for code in [
            LibvirtErrorCode.agentUnresponsive, .agentCommandTimeout, .agentCommandFailed, .agentUnsynced,
        ] {
            #expect(LibvirtFailure.isGuestAgentUnavailable(daemonError(code)), "code \(code)")
        }
        #expect(!LibvirtFailure.isGuestAgentUnavailable(daemonError(.internalError)))
        #expect(!LibvirtFailure.isGuestAgentUnavailable(daemonError(.noDomain)))
        #expect(!LibvirtFailure.isGuestAgentUnavailable(LibvirtClientError(.connectionClosed)))
    }

    // MARK: - Lifecycle events

    @Test("Every virDomainEventType has a label")
    func labelsEveryLifecycleEvent() {
        let expected: [LibvirtDomain.LifecycleEvent: String] = [
            .defined: "defined",
            .undefined: "undefined",
            .started: "started",
            .suspended: "suspended",
            .resumed: "resumed",
            .stopped: "stopped",
            .shutdown: "shutdown",
            .pmSuspended: "pm-suspended",
            .crashed: "crashed",
        ]
        for event in LibvirtDomain.LifecycleEvent.allCases {
            #expect(event.label == expected[event], "event \(event)")
        }
        #expect(LibvirtDomain.LifecycleEvent.allCases.count == expected.count)
        // The raw values are libvirt's, not ours: a transposition here would
        // mislabel every log line about a guest that powered itself off.
        #expect(LibvirtDomain.lifecycleEventLabel(forRawEvent: 5) == "stopped")
        #expect(LibvirtDomain.lifecycleEventLabel(forRawEvent: 2) == "started")
    }

    /// The deliberate opposite of `unknownStateIsNotGuessed`. A *state* this
    /// build cannot read must become `.unknown` so nothing acts on a guess; an
    /// *event* it cannot read must still be delivered, because the only thing
    /// an event does is schedule a re-reading of the truth.
    @Test("An unrecognised event is named, never swallowed")
    func unknownLifecycleEventIsStillDelivered() {
        #expect(LibvirtDomain.lifecycleEventLabel(forRawEvent: 42) == "event-42")
        #expect(LibvirtDomain.lifecycleEventLabel(forRawEvent: -1) == "event--1")
    }

    // MARK: - Domain naming

    @Test("Only UUID-named domains are read as this agent's")
    func stratoDomainNames() {
        #expect(LibvirtDomain.isStratoDomainName("0F9EA1B2-3C4D-4E5F-8A9B-0C1D2E3F4A5B"))
        #expect(LibvirtDomain.isStratoDomainName("0f9ea1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b"))
        // A co-tenant domain on the same libvirtd would otherwise be reported to
        // the control plane as a Strato VM, and counted against this host's
        // capacity.
        #expect(!LibvirtDomain.isStratoDomainName("ubuntu-24.04"))
        #expect(!LibvirtDomain.isStratoDomainName(""))
        #expect(!LibvirtDomain.isStratoDomainName("win11"))
    }

    // MARK: - Failure classification

    private func daemonError(_ code: LibvirtErrorCode, _ message: String = "boom") -> LibvirtError {
        LibvirtError(code: code, domain: 10, message: message, level: .error)
    }

    @Test("A missing domain is distinguishable from every other daemon error")
    func classifiesMissingDomain() {
        #expect(LibvirtFailure.isDomainMissing(daemonError(.noDomain)))
        #expect(!LibvirtFailure.isDomainMissing(daemonError(.operationInvalid)))
        #expect(!LibvirtFailure.isDomainMissing(daemonError(.internalError)))
        #expect(!LibvirtFailure.isDomainMissing(LibvirtClientError(.connectionClosed)))
    }

    @Test("A state-refused command is distinguishable, and only that code counts")
    func classifiesOperationInvalid() {
        #expect(LibvirtFailure.isOperationInvalid(daemonError(.operationInvalid, "domain is already running")))
        #expect(!LibvirtFailure.isOperationInvalid(daemonError(.operationFailed)))
        #expect(!LibvirtFailure.isOperationInvalid(daemonError(.noDomain)))
    }

    /// The one classification that reads a message rather than a code, because
    /// libvirt reports a full root complex as a bare `internalError`. It exists
    /// only to reword the error a hot-plug fails with (STR-192), so the cases
    /// that matter are that it recognizes libvirt's wording and does not claim
    /// every other internal error.
    @Test("A full root complex is recognized by its message, and nothing else is")
    func classifiesExhaustedPCISlots() {
        #expect(
            LibvirtFailure.isPCISlotsExhausted(
                daemonError(.internalError, "No more available PCI slots")))
        // libvirt prefixes and wraps this text on its way out; the match has to
        // survive that, and the daemon's own casing is not a contract either.
        #expect(
            LibvirtFailure.isPCISlotsExhausted(
                daemonError(.internalError, "internal error: no more available PCI slots")))
        #expect(!LibvirtFailure.isPCISlotsExhausted(daemonError(.internalError, "boom")))
        #expect(!LibvirtFailure.isPCISlotsExhausted(daemonError(.operationFailed)))
        #expect(!LibvirtFailure.isPCISlotsExhausted(LibvirtClientError(.connectionClosed)))
    }

    @Test("Only a dead channel drops the cached connection")
    func classifiesConnectionLoss() {
        for code in [
            LibvirtClientError.Code.connectionClosed, .keepaliveTimeout, .notConnected, .protocolError,
            .handshakeFailed,
        ] {
            #expect(LibvirtFailure.isConnectionLost(LibvirtClientError(code)), "code \(code)")
        }
        // A slow command says nothing about the channel, and tearing down a
        // healthy connection over one would take every other VM on the host
        // with it.
        for code in [LibvirtClientError.Code.deadlineExceeded, .cancelled, .authenticationUnsupported] {
            #expect(!LibvirtFailure.isConnectionLost(LibvirtClientError(code)), "code \(code)")
        }
        // A daemon error is the command failing, not the connection.
        #expect(!LibvirtFailure.isConnectionLost(daemonError(.internalError)))
    }

    // MARK: - Error translation

    @Test("A missing domain becomes vmNotFound, which the control plane reads specially")
    func translatesMissingDomain() {
        let error = LibvirtFailure.hypervisorError(daemonError(.noDomain), vmId: "vm-1", operation: "status")
        guard case .vmNotFound(let vmId) = error else {
            Issue.record("expected vmNotFound, got \(error)")
            return
        }
        #expect(vmId == "vm-1")
    }

    @Test("Timeouts stay timeouts, whether the daemon or the client raised them")
    func translatesTimeouts() {
        for error in [
            LibvirtFailure.hypervisorError(daemonError(.operationTimeout), vmId: "vm-1", operation: "boot"),
            LibvirtFailure.hypervisorError(daemonError(.agentCommandTimeout), vmId: "vm-1", operation: "boot"),
            LibvirtFailure.hypervisorError(
                LibvirtClientError(.deadlineExceeded), vmId: "vm-1", operation: "boot"),
            LibvirtFailure.hypervisorError(LibvirtClientError(.cancelled), vmId: "vm-1", operation: "boot"),
        ] {
            guard case .timeout = error else {
                Issue.record("expected timeout, got \(error)")
                continue
            }
        }
    }

    @Test("An unsupported operation is reported as such, not as a configuration fault")
    func translatesUnsupported() {
        for code in [
            LibvirtErrorCode.noSupport, .operationUnsupported, .configUnsupported, .argumentUnsupported,
        ] {
            let error = LibvirtFailure.hypervisorError(daemonError(code), vmId: "vm-1", operation: "checkpoint")
            guard case .notSupported = error else {
                Issue.record("expected notSupported for \(code), got \(error)")
                continue
            }
        }
    }

    /// The single most likely libvirt failure on a fresh node, and the one whose
    /// generic message helps least: `/etc/libvirt/qemu.conf` not naming the
    /// account the agent runs as.
    @Test("A permission failure names the qemu.conf remedy")
    func translatesAccessDenied() {
        let error = LibvirtFailure.hypervisorError(
            daemonError(.accessDenied, "permission denied"), vmId: "vm-1", operation: "define")
        guard case .invalidConfiguration(let detail) = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
        #expect(detail.contains("qemu.conf"))
        #expect(detail.contains("qemu:///system"))
    }

    @Test("Anything else carries libvirt's own message, which is what reaches the UI")
    func translationPreservesMessage() {
        let error = LibvirtFailure.hypervisorError(
            daemonError(.internalError, "unsupported configuration: unknown device 'virtio-mem'"),
            vmId: "vm-1", operation: "define")
        #expect(error.errorDescription?.contains("unknown device 'virtio-mem'") == true)
        #expect(error.errorDescription?.contains("define") == true)
    }

    @Test("An already-typed hypervisor error passes through unchanged")
    func translationIsIdempotent() {
        let original = HypervisorServiceError.diskError("no file")
        let error = LibvirtFailure.hypervisorError(original, vmId: "vm-1", operation: "create")
        guard case .diskError(let detail) = error else {
            Issue.record("expected diskError, got \(error)")
            return
        }
        #expect(detail == "no file")
    }

    // MARK: - Memory statistics

    private func stat(_ tag: Int32, kib: UInt64) -> DomainMemoryStat {
        DomainMemoryStat(tag: tag, val: kib)
    }

    @Test("Balloon statistics are converted from KiB and mapped onto the reported fields")
    func parsesMemoryStats() throws {
        let stats = try #require(
            LibvirtMemoryStats.parse([
                stat(0, kib: 0),  // SWAP_IN, dropped
                stat(4, kib: 512 * 1024),  // UNUSED -> freeBytes
                stat(5, kib: 2 * 1024 * 1024),  // AVAILABLE -> totalBytes
                stat(6, kib: 2 * 1024 * 1024),  // ACTUAL_BALLOON
                stat(7, kib: 1024),  // RSS, dropped
                stat(8, kib: 1536 * 1024),  // USABLE -> availableBytes
            ]))

        // Explicitly `Int64` on both sides: an untyped literal against an
        // `Int64?` resolves through `AnyHashable`, where an `Int` and an `Int64`
        // of the same value are not equal — the assertion then fails while
        // printing two identical numbers.
        #expect(stats.totalBytes == Int64(2 * 1024 * 1024 * 1024))
        #expect(stats.availableBytes == Int64(1536 * 1024 * 1024))
        #expect(stats.balloonActualBytes == Int64(2 * 1024 * 1024 * 1024))
    }

    /// Absence is how libvirt reports a stat the guest driver has not answered
    /// — it omits the tag rather than sending QEMU's `-1` sentinel — so a guest
    /// still booting produces nothing, and nothing must never read as zero.
    @Test("Without the load-bearing pair there is nothing truthful to report")
    func missingPairReportsNothing() {
        #expect(LibvirtMemoryStats.parse([]) == nil)
        // ACTUAL_BALLOON comes from QEMU rather than the guest, so it arrives
        // long before the driver loads. On its own it is not usage.
        #expect(LibvirtMemoryStats.parse([stat(6, kib: 2 * 1024 * 1024)]) == nil)
        #expect(LibvirtMemoryStats.parse([stat(5, kib: 1024)]) == nil)
        #expect(LibvirtMemoryStats.parse([stat(8, kib: 1024)]) == nil)
    }

    @Test("Optional stats are absent rather than zero when the guest omits them")
    func optionalStatsStayNil() throws {
        let stats = try #require(
            LibvirtMemoryStats.parse([stat(5, kib: 1024), stat(8, kib: 512)]))
        #expect(stats.balloonActualBytes == nil)
    }

    @Test("A value that cannot be a byte count is dropped rather than wrapped")
    func rejectsOverflowingStats() {
        // libvirt types these as `unsigned long long`; a KiB figure this large
        // is corrupt, and reporting it wrapped would be worse than reporting
        // nothing.
        #expect(LibvirtMemoryStats.parse([stat(5, kib: .max), stat(8, kib: 512)]) == nil)
        let partial = LibvirtMemoryStats.parse([stat(5, kib: 1024), stat(8, kib: 512), stat(4, kib: .max)])
        #expect(partial?.balloonActualBytes == nil)
    }

    // MARK: - Host reservations

    /// A real `REMOTE_PROC_DOMAIN_GET_INFO` reply for a running two-vCPU domain
    /// with an 8 GiB ceiling, captured off the wire from libvirtd.
    ///
    /// Decoded here rather than constructed, because what broke was the decode:
    /// `state` is an `unsigned char`, which XDR sends as a whole four-byte word,
    /// and a client reading it as a length-prefixed byte string consumed the
    /// head of `maxMem` and shifted every field behind it. `reservedResources`
    /// swallows that failure by design — it serves the last good answer — and
    /// the last good answer is `(0, 0)`, recorded legitimately back when the
    /// host had no Strato domains to sweep. So the first VM defined on a host
    /// turned every later sweep into a stale read of that zero while the node
    /// went on advertising its full capacity to the scheduler. Nothing about
    /// that is visible above this line: a zero from a genuinely empty host and a
    /// zero from a decoder that has never once worked read identically.
    static let runningDomainInfoReply: [UInt8] = [
        0x00, 0x00, 0x00, 0x01,  // state: VIR_DOMAIN_RUNNING, one whole word
        0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00,  // maxMem: 8 GiB, in KiB
        0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00,  // memory: current balloon
        0x00, 0x00, 0x00, 0x02,  // nrVirtCpu
        0x18, 0xC9, 0xD6, 0xC1, 0xDA, 0x65, 0xA5, 0x18,  // cpuTime
    ]

    @Test("A running domain reserves what it was given, decoded from the daemon's own bytes")
    func reservationFromWireBytes() throws {
        var buffer = ByteBuffer(bytes: Self.runningDomainInfoReply)
        let info = try DomainGetInfoRet(fromXDR: &buffer)
        #expect(buffer.readableBytes == 0)

        let reserved = LibvirtDomain.reservation(from: info)
        #expect(reserved.vcpus == 2)
        #expect(reserved.memoryBytes == Int64(8) * 1024 * 1024 * 1024)
    }

    /// `maxMem`, not `memory`: the live figure is the current balloon setting,
    /// so an inflated balloon would read as the guest handing its grant back to
    /// a host that cannot actually re-lend it.
    @Test("The ceiling is reserved, not the balloon's current setting")
    func reservesTheCeilingNotTheBalloon() {
        let info = DomainGetInfoRet(
            state: 1, maxMem: 8 * 1024 * 1024, memory: 512 * 1024, nrVirtCpu: 4, cpuTime: 0)
        let reserved = LibvirtDomain.reservation(from: info)
        #expect(reserved.vcpus == 4)
        #expect(reserved.memoryBytes == Int64(8) * 1024 * 1024 * 1024)
    }

    /// A stopped domain still holds its placement and its disks, and
    /// `reservedResources` counts it deliberately — `listAllDomains` is asked
    /// for every domain, not just the running ones.
    @Test("A defined-but-stopped domain still reserves its grant")
    func stoppedDomainStillReserves() {
        let info = DomainGetInfoRet(
            state: 5, maxMem: 2 * 1024 * 1024, memory: 0, nrVirtCpu: 1, cpuTime: 0)
        let reserved = LibvirtDomain.reservation(from: info)
        #expect(reserved.vcpus == 1)
        #expect(reserved.memoryBytes == Int64(2) * 1024 * 1024 * 1024)
    }

    /// The sentence STR-190 made false, asserted on the sum rather than on a
    /// domain: no arrangement of live domains adds up to an idle host. A
    /// per-domain test cannot say this — the bug produced no per-domain answers
    /// at all, and the fold over nothing is what read as zero.
    @Test("A host with domains on it never reports zero")
    func aPopulatedHostNeverReadsIdle() {
        let infos = [
            DomainGetInfoRet(state: 1, maxMem: 4 * 1024 * 1024, memory: 0, nrVirtCpu: 2, cpuTime: 0),
            DomainGetInfoRet(state: 5, maxMem: 2 * 1024 * 1024, memory: 0, nrVirtCpu: 1, cpuTime: 0),
            DomainGetInfoRet(state: 3, maxMem: 1024 * 1024, memory: 0, nrVirtCpu: 1, cpuTime: 0),
        ]
        let reserved = LibvirtDomain.reservation(from: infos)
        #expect(reserved.vcpus == 4)
        #expect(reserved.memoryBytes == Int64(7) * 1024 * 1024 * 1024)
    }

    /// The one host that truthfully reserves nothing — and the state the cached
    /// zero in STR-190 was legitimately recorded from, before the first VM
    /// landed and every later sweep started failing back onto it.
    @Test("A host with no domains reserves nothing")
    func anEmptyHostReservesNothing() {
        let reserved = LibvirtDomain.reservation(from: [])
        #expect(reserved.vcpus == 0)
        #expect(reserved.memoryBytes == 0)
    }

    /// Saturation, not a trap. `maxMem` here is the eight bytes of `cpuTime`
    /// from the golden reply above — what the STR-190 misalignment actually
    /// delivered into this field — and `× 1024` on it overflows `Int64`. The
    /// agent reporting an absurd reservation for one heartbeat is recoverable;
    /// the agent crashing inside the heartbeat's task group is not.
    @Test("A corrupt memory ceiling saturates rather than trapping")
    func absurdCeilingSaturates() {
        let misaligned = DomainGetInfoRet(
            state: 1, maxMem: 0x18C9_D6C1_DA65_A518, memory: 0, nrVirtCpu: 2, cpuTime: 0)
        #expect(LibvirtDomain.reservation(from: misaligned).memoryBytes == .max)

        let maximal = DomainGetInfoRet(
            state: 1, maxMem: .max, memory: 0, nrVirtCpu: .max, cpuTime: 0)
        #expect(LibvirtDomain.reservation(from: maximal).memoryBytes == .max)
        #expect(LibvirtDomain.reservation(from: maximal).vcpus == Int(UInt32.max))

        // And the fold over them, which would otherwise trap on the addition.
        let total = LibvirtDomain.reservation(from: [maximal, maximal])
        #expect(total.memoryBytes == .max)
    }
}
