import Foundation
import Libvirt
import StratoShared

/// The parts of libvirt's domain vocabulary the agent has to own itself.
///
/// swift-libvirt models the **wire**: the XDR structs and procedures in
/// `remote_protocol.x`. It deliberately models nothing above that — no domain
/// XML, and none of the C enums and flag bitmasks that live in `libvirt.h`
/// rather than in the protocol. So the driver's state mapping, its flag
/// constants and its error translation are Strato's to define, and they live
/// here for the reason `DomainXMLBuilder` gives: `LibvirtService` links a
/// hypervisor SDK and therefore has no unit tests, while a wrong bit in an
/// undefine mask or a mis-mapped domain state is silent, host-wide, and only
/// visible as VMs behaving strangely much later.
public enum LibvirtDomain {

    // MARK: - Domain state

    /// `virDomainState`, as returned by `virDomainGetState`.
    ///
    /// Mapping to `VMStatus` is markedly simpler than
    /// `QEMUService.vmStatus(from:awaitingFirstStart:)`, and the reason is the
    /// create path rather than this enum: `domainDefineXML` leaves the domain
    /// `SHUTOFF`, which satisfies `ReconcileStep.create`'s "exists, not
    /// running" contract directly. There is no `prelaunch`-versus-`paused`
    /// ambiguity to recover from the driver's own memory, so there is no
    /// `awaitingFirstStart` and no extra bit to carry.
    public enum State: Int32, Sendable, CaseIterable {
        case noState = 0
        case running = 1
        case blocked = 2
        case paused = 3
        case shuttingDown = 4
        case shutoff = 5
        case crashed = 6
        case pmSuspended = 7

        public var vmStatus: VMStatus {
            switch self {
            case .running, .blocked:
                // `blocked` is a running domain stalled on I/O — libvirt's own
                // docs call it "running but blocked on resource". The guest is
                // live and the operator's intent is satisfied.
                return .running
            case .paused, .pmSuspended:
                // `pmSuspended` is a guest that suspended *itself* (S3), which
                // nothing in Strato asks for — we never issue
                // `virDomainPMSuspendForDuration`. It is reported as paused
                // because that is what it looks like from outside; note that a
                // resume would need `virDomainPMWakeup` rather than
                // `virDomainResume`, which is a gap only a guest that suspends
                // on its own can reach.
                return .paused
            case .shuttingDown, .shutoff:
                return .shutdown
            case .crashed:
                // Unreachable under the document we define: `<on_crash>` is
                // `destroy`, so libvirt tears a panicked domain down to
                // `shutoff` instead of parking it here. Reported honestly
                // rather than laundered into `.shutdown` — a guest that
                // crashed is not a guest that stopped.
                return .error
            case .noState:
                return .unknown
            }
        }

        /// Whether libvirt considers the domain *active* — the question a
        /// delete asks before it unlinks the VM's disks, and an adoption asks
        /// before it reports the VM back as managed.
        public var isActive: Bool {
            switch self {
            case .running, .blocked, .paused, .pmSuspended, .shuttingDown:
                return true
            case .shutoff, .crashed, .noState:
                return false
            }
        }
    }

    /// The status to report for a raw `virDomainGetState` value. An
    /// unrecognised state is `.unknown`, never a guess: the enum is append-only
    /// upstream, and inventing a status for a state this build has never heard
    /// of is how a newer libvirt would make the reconciler act on a fiction.
    public static func vmStatus(forRawState raw: Int32) -> VMStatus {
        State(rawValue: raw)?.vmStatus ?? .unknown
    }

    /// Whether a raw `virDomainGetState` value describes an active domain.
    /// Unknown states count as active, which is the safe end of the trade: the
    /// caller that asks is about to unlink a disk.
    public static func isActive(rawState raw: Int32) -> Bool {
        State(rawValue: raw)?.isActive ?? true
    }

    // MARK: - Flags

    /// `virDomainCreateFlags.VIR_DOMAIN_NONE` — start the domain and run it.
    ///
    /// Deliberately **not** `VIR_DOMAIN_START_PAUSED`. The QEMU driver spawns
    /// with `-S` because its create and its boot are the same act; here they
    /// are not, and a domain that has been defined but never started is already
    /// in the state the create contract asks for.
    public static let startFlags: UInt32 = 0

    /// `virDomainShutdownFlagValues.VIR_DOMAIN_SHUTDOWN_DEFAULT` — let libvirt
    /// pick, which tries the guest agent and falls back to the ACPI power
    /// button. Naming a single method here would throw away the verified
    /// shutdown `QEMUService` reaches for qga to get.
    public static let shutdownFlags: UInt32 = 0

    /// `virDomainDestroyFlagsValues.VIR_DOMAIN_DESTROY_GRACEFUL` — SIGTERM the
    /// emulator and only escalate to SIGKILL if it does not go, rather than
    /// killing it outright.
    public static let destroyGraceful: UInt32 = 1 << 0

    /// `virDomainUndefineFlagsValues`, as one mask. Every bit is load-bearing:
    ///
    /// - `MANAGED_SAVE` (1) and `SNAPSHOTS_METADATA` (2) / `CHECKPOINTS_METADATA`
    ///   (16): libvirt **refuses** an undefine that would strand any of these,
    ///   so a domain that was ever checkpointed becomes undeletable without
    ///   them — and the delete then leaves the VM's directory on the host on
    ///   every retry.
    /// - `NVRAM` (4): removes the UEFI varstore. Redundant with the recursive
    ///   directory removal today, since the document puts the varstore inside
    ///   the VM's own directory, but it is what keeps the undefine honest if
    ///   that ever moves.
    /// - `TPM` (32): removes swtpm's per-domain state. This one is **not**
    ///   redundant: libvirt keeps it under `/var/lib/libvirt/swtpm/<uuid>`,
    ///   outside anything the agent reclaims, so without this bit every
    ///   TPM-backed VM leaks its vTPM state directory forever.
    public static let undefineFlags: UInt32 =
        (1 << 0)  // VIR_DOMAIN_UNDEFINE_MANAGED_SAVE
        | (1 << 1)  // VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA
        | (1 << 2)  // VIR_DOMAIN_UNDEFINE_NVRAM
        | (1 << 4)  // VIR_DOMAIN_UNDEFINE_CHECKPOINTS_METADATA
        | (1 << 5)  // VIR_DOMAIN_UNDEFINE_TPM

    /// `virConnectListAllDomainsFlags` with no filter: persistent and
    /// transient, running and not. A Strato VM that is defined-but-off is as
    /// real as a running one — it holds its disks and its placement — so
    /// filtering to active domains here would make every stopped VM look
    /// deleted to the control plane.
    public static let listAllDomains: UInt32 = 0

    /// The `maxStats` a memory-stats call makes room for. Comfortably above
    /// `VIR_DOMAIN_MEMORY_STAT_NR` on purpose: libvirt truncates its reply to
    /// this count, and a buffer sized to the tags actually read would silently
    /// drop them as soon as a newer daemon appended a stat ahead of them.
    public static let memoryStatSlots: UInt32 = 16

    // MARK: - Domain identity

    /// Whether a libvirt domain name is one of ours.
    ///
    /// `DomainXMLBuilder` writes the VM id into `<name>` and the control plane
    /// only ever issues UUIDs, so this is exact rather than a heuristic. It
    /// matters because both `listVMs()` and `reservedResources()` read the
    /// daemon's full domain list, and *that list is not advisory*: a VM absent
    /// from the heartbeat is marked `.error` by the control plane, and a
    /// co-tenant domain present in it would be reported as a Strato VM that no
    /// sync can explain.
    public static func isStratoDomainName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }
}

// MARK: - Error classification

/// Reading libvirt's failures the way the agent's callers need them.
///
/// Kept separate from the translation below because the two questions are
/// different: "is this failure actually a success in disguise" is asked before
/// a command's post-condition is re-checked, while the translation is what
/// reaches the reconciler's `lastError` and, from there, the UI.
public enum LibvirtFailure {

    /// libvirt's answer when a lookup names a domain it does not have
    /// (`VIR_ERR_NO_DOMAIN`). The one error every caller has to distinguish:
    /// it is "not found" for a status query, "nothing to tear down" for a
    /// delete, and "re-create it from the manifest" for an adoption.
    public static func isDomainMissing(_ error: any Error) -> Bool {
        (error as? LibvirtError)?.code == .noDomain
    }

    /// `VIR_ERR_OPERATION_INVALID` — libvirt refusing a command because of the
    /// domain's current state ("domain is already running", "domain is not
    /// running", "domain is not active").
    ///
    /// Deliberately only a *signal*, never translated straight into success:
    /// the same code covers refusals that are real (undefining a transient
    /// domain, for one), and the message text is not a contract. Callers answer
    /// it by re-reading the domain's state and asking whether their
    /// post-condition holds anyway, which is a fact rather than a guess.
    public static func isOperationInvalid(_ error: any Error) -> Bool {
        (error as? LibvirtError)?.code == .operationInvalid
    }

    /// Whether the *connection* is what failed, rather than the command.
    ///
    /// `LibvirtClient` never reconnects by design — once the channel is gone
    /// every call on it throws — so this is what tells the driver to drop its
    /// cached client and redial on the next call instead of reporting a dead
    /// socket as a VM problem for the rest of the agent's life.
    public static func isConnectionLost(_ error: any Error) -> Bool {
        guard let error = error as? LibvirtClientError else { return false }
        switch error.code {
        case .connectionClosed, .keepaliveTimeout, .notConnected, .protocolError, .handshakeFailed:
            return true
        case .deadlineExceeded, .cancelled, .authenticationUnsupported:
            // A call that ran out of time (or was cancelled by its stage
            // budget) says nothing about the channel, and tearing down a
            // healthy connection over one slow command would take every other
            // VM on the host with it. Authentication is a configuration fault
            // that a redial reproduces exactly.
            return false
        }
    }

    /// Translates a libvirt failure into the agent's hypervisor error
    /// vocabulary, preserving libvirt's own message — which is what lands in
    /// the reconciler's `lastError` and the failed operation the UI shows.
    ///
    /// - Parameters:
    ///   - vmId: the VM the command was for.
    ///   - operation: a short verb for the log and the message ("boot",
    ///     "define", "undefine"), so an opaque daemon error at least names what
    ///     was being attempted.
    public static func hypervisorError(
        _ error: any Error, vmId: String, operation: String
    ) -> HypervisorServiceError {
        if let error = error as? LibvirtError {
            switch error.code {
            case .noDomain:
                return .vmNotFound(vmId)
            case .operationTimeout, .agentCommandTimeout:
                return .timeout("\(operation) for VM \(vmId): \(error.message)")
            case .noSupport, .operationUnsupported, .configUnsupported, .argumentUnsupported:
                return .notSupported("\(operation) for VM \(vmId): \(error.message)")
            case .accessDenied, .operationDenied, .authFailed:
                // Almost always `/etc/libvirt/qemu.conf` not matching the
                // account the agent runs as — the invariant `install.sh` sets
                // up — so it is worth not burying under a generic error.
                return .invalidConfiguration(
                    "libvirt denied \(operation) for VM \(vmId): \(error.message). Check that the agent's account "
                        + "may reach \(LibvirtProbe.systemURI) and that /etc/libvirt/qemu.conf names it.")
            default:
                return .invalidConfiguration("libvirt \(operation) failed for VM \(vmId): \(error.message)")
            }
        }
        if let error = error as? LibvirtClientError {
            switch error.code {
            case .deadlineExceeded, .cancelled:
                return .timeout("\(operation) for VM \(vmId): \(error.description)")
            default:
                return .invalidConfiguration(
                    "libvirt connection failed during \(operation) for VM \(vmId): \(error.description)")
            }
        }
        if let error = error as? HypervisorServiceError {
            return error
        }
        return .invalidConfiguration(
            "\(operation) failed for VM \(vmId): \(error.localizedDescription)")
    }
}

// MARK: - Memory statistics

/// `virDomainMemoryStats` → `VMMemoryStats`.
///
/// libvirt reports the same virtio-balloon guest statistics QEMU exposes
/// through `qom-get guest-stats`, tagged and in KiB, so this is the libvirt
/// spelling of `QMPProbeClient.collectMemoryStats` and follows its rule
/// exactly: without the load-bearing pair there is nothing truthful to report,
/// and nil means "no stats", never "no memory used".
///
/// Where the two differ is what an unreported stat looks like. QEMU sends `-1`
/// for a stat the guest driver has not answered; libvirt omits the tag
/// entirely. So absence, not a sentinel, is what this reads.
public enum LibvirtMemoryStats {

    /// `virDomainMemoryStatTags`. Only the four Strato reports are named; the
    /// rest (swap, faults, RSS, disk caches, hugetlb) are collected by the
    /// daemon and dropped here.
    enum Tag: Int32 {
        /// `VIR_DOMAIN_MEMORY_STAT_UNUSED`: strictly free guest pages.
        case unused = 4
        /// `VIR_DOMAIN_MEMORY_STAT_AVAILABLE`: total memory the guest sees.
        case available = 5
        /// `VIR_DOMAIN_MEMORY_STAT_ACTUAL_BALLOON`: what the balloon currently
        /// leaves the guest. Comes from QEMU rather than the guest, so it is
        /// present even where the guest driver never loaded.
        case actualBalloon = 6
        /// `VIR_DOMAIN_MEMORY_STAT_USABLE`: memory available for new
        /// allocations without swapping — free pages plus reclaimable caches.
        case usable = 8
    }

    /// The stats to report, or nil when the guest's balloon driver has not
    /// answered yet.
    ///
    /// `available` and `usable` are the pair that must both be present:
    /// `VMMemoryStats` types them non-optional because they are the two figures
    /// the whole struct exists to carry, and a guest still booting reports
    /// neither.
    public static func parse(_ stats: [DomainMemoryStat]) -> VMMemoryStats? {
        var byTag: [Int32: UInt64] = [:]
        for stat in stats {
            // Last write wins, which matters only for a daemon that repeated a
            // tag; libvirt does not.
            byTag[stat.tag] = stat.val
        }

        guard let total = bytes(byTag[Tag.available.rawValue]),
            let available = bytes(byTag[Tag.usable.rawValue])
        else { return nil }

        return VMMemoryStats(
            totalBytes: total,
            availableBytes: available,
            freeBytes: bytes(byTag[Tag.unused.rawValue]),
            balloonActualBytes: bytes(byTag[Tag.actualBalloon.rawValue]))
    }

    /// KiB → bytes, refusing a value that cannot be represented. libvirt's
    /// stats are `unsigned long long` on the wire; a value that overflows a
    /// signed 64-bit byte count is corrupt rather than large, and reporting it
    /// wrapped would be worse than reporting nothing.
    private static func bytes(_ kib: UInt64?) -> Int64? {
        guard let kib, let value = Int64(exactly: kib), value <= Int64.max / 1024 else { return nil }
        return value * 1024
    }
}
