import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// Console access points a hypervisor exposes for a VM.
/// A backend may offer a serial socket, a virtio-console socket, a VNC socket,
/// any combination, or none.
///
/// The text and graphics consoles are independent, not ranked: for text,
/// consumers try `serialSocketPath` first and fall back to `consoleSocketPath`;
/// `vncSocketPath` is only ever used for a graphics session and has no
/// fallback, since serial bytes are not an RFB stream (issue #566).
public struct ConsoleEndpoint: Sendable {
    /// Unix socket path for the VM's serial console, if available
    public let serialSocketPath: String?

    /// Unix socket path for the VM's virtio-console, if available
    public let consoleSocketPath: String?

    /// Unix socket path for the VM's VNC server, present only when the VM was
    /// spawned with a graphics console. Absent means the guest is headless —
    /// which is not recoverable without recreating it, since the display device
    /// is fixed in the QEMU process's arguments.
    public let vncSocketPath: String?

    public init(serialSocketPath: String?, consoleSocketPath: String?, vncSocketPath: String? = nil) {
        self.serialSocketPath = serialSocketPath
        self.consoleSocketPath = consoleSocketPath
        self.vncSocketPath = vncSocketPath
    }

    /// True when no socket at all is available
    public var isEmpty: Bool {
        serialSocketPath == nil && consoleSocketPath == nil && vncSocketPath == nil
    }
}

/// What a completed full-VM checkpoint captured (issue #564), for the control
/// plane's snapshot record.
public struct VMCheckpointReport: Sendable {
    /// Bytes of guest RAM + device state the backend wrote, or nil when it
    /// reported no size for the checkpoint it just took. Nil is "unknown",
    /// never "empty".
    public let vmStateSizeBytes: Int64?
    /// Backend-native names of the storage the checkpoint spans, for
    /// diagnostics.
    public let deviceNodes: [String]
    /// The hypervisor build that captured the checkpoint. A restore needs a
    /// compatible one.
    public let hypervisorVersion: String?

    public init(vmStateSizeBytes: Int64?, deviceNodes: [String], hypervisorVersion: String?) {
        self.vmStateSizeBytes = vmStateSizeBytes
        self.deviceNodes = deviceNodes
        self.hypervisorVersion = hypervisorVersion
    }
}

/// Protocol defining the interface for hypervisor services
/// Both LibvirtService and FirecrackerService conform to this protocol
public protocol HypervisorService: Actor, Sendable {
    /// The type of hypervisor
    var hypervisorType: HypervisorType { get }

    /// Creates a VM from a hypervisor-neutral spec. The service translates the
    /// spec into its driver-native configuration (paths, sockets, machine types).
    ///
    /// Network attachments are resolved by the agent's `NetworkOrchestrator`
    /// before this call and torn down by it after `deleteVM` — drivers only
    /// translate each `NetworkAttachment` into their native NIC configuration,
    /// throwing `HypervisorServiceError.notSupported` for kinds their backend
    /// cannot realize.
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - spec: Hypervisor-neutral VM specification
    ///   - imageInfo: Optional image info for disk caching
    ///   - networkAttachments: Host-realized NICs, in `spec.networks` order
    ///   - metadata: What the control plane publishes about this instance, from
    ///     the desired-state sync. A driver's guest-bootstrap media renders from
    ///     it — today only the hostname, which the seed ISO must agree with
    ///     because the same value is what the VM's DNS zone is assembled from
    ///     (STR-177). Guest-provisioning *payloads* still come from the spec:
    ///     `sshAuthorizedKeys`/`userData` are duplicated here for the running
    ///     guest to re-read, not for boot. Nil when the control plane sent none
    ///     (pre-STR-51), which is not an instruction — just nothing to render.
    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?, networkAttachments: [ResolvedNetworkAttachment],
        metadata: InstanceMetadata?
    ) async throws

    /// Makes whatever stored configuration this backend holds for a *stopped*
    /// VM able to satisfy `spec`, before the boot that will read it (STR-187).
    ///
    /// A backend that rebuilds a VM from its spec on every spawn needs nothing
    /// here — that is what its spawn already does, and the default is a no-op
    /// for exactly those backends. It exists
    /// for `LibvirtService`, where the domain document is written at create and
    /// the next boot reads *that* rather than the spec: a VM's hot-plug slots,
    /// its memory headroom and its vCPU maximum would otherwise be fixed for its
    /// whole life, and outgrowing any of them would leave "recreate the VM" as
    /// the only remedy.
    ///
    /// Called before `bootVM` and **never for a VM being created**, whose
    /// configuration was built from this spec moments earlier. Best-effort by
    /// contract: the caller boots the VM whether or not this succeeded, since a
    /// VM that comes up at the ceiling it already had is strictly better than
    /// one that does not come up. What the widening could not deliver surfaces
    /// where it is actionable — on the attach or the resize that wanted it.
    ///
    /// - Parameters:
    ///   - vmId: The VM identifier
    ///   - spec: The desired spec this boot is converging on
    func redefineVM(vmId: String, spec: VMSpec) async throws

    /// Converges the backend's process-memory ceiling before a boot. Backends
    /// without a persistent VMM process definition use the default no-op;
    /// libvirt treats this as required whenever cgroup memory support exists.
    func ensureMemoryCeiling(vmId: String, spec: VMSpec) async throws

    /// Boots (starts) a VM
    /// - Parameter vmId: The VM identifier
    func bootVM(vmId: String) async throws

    /// Shuts down a VM gracefully
    /// - Parameter vmId: The VM identifier
    func shutdownVM(vmId: String) async throws

    /// Reboots a VM
    /// - Parameter vmId: The VM identifier
    func rebootVM(vmId: String) async throws

    /// Pauses a running VM
    /// - Parameter vmId: The VM identifier
    func pauseVM(vmId: String) async throws

    /// Resumes a paused VM
    /// - Parameter vmId: The VM identifier
    func resumeVM(vmId: String) async throws

    /// Deletes a VM and cleans up resources
    /// - Parameter vmId: The VM identifier
    func deleteVM(vmId: String) async throws

    /// Removes what the VM left on this host, for a delete that has no session
    /// to tear down (STR-179).
    ///
    /// `deleteVM` is the normal route and reclaims the same state on its way
    /// out. This is for the one path that cannot reach it: an orphan whose
    /// re-adoption reported the hypervisor process *gone*, so there is nothing
    /// to destroy — while its boot disk, cloud-init ISO and the rest of its
    /// directory are still on the host. That delete then drops the VM's
    /// manifest entry, the last thing on the host that knows the VM was ever
    /// here, so anything left behind is leaked for good.
    ///
    /// Callers must hold that evidence: this unlinks the disk a live guest
    /// would still be running from. Best-effort and non-throwing — the delete
    /// releases the manifest entry either way, so a failure here is loud in
    /// the log rather than something a caller can act on — and a backend with
    /// nothing on disk implements it as a no-op.
    /// - Parameter vmId: The VM identifier
    func reclaimVMDirectory(vmId: String) async

    /// Gets the current status of a VM
    /// - Parameter vmId: The VM identifier
    /// - Returns: The current VM status
    func getVMStatus(vmId: String) async throws -> VMStatus

    /// Every VM id this service manages, or nil if it cannot say (STR-196).
    ///
    /// The empty list is an *answer*, not a shrug: it claims this backend
    /// manages nothing, and absence from an inventory of what exists on a host
    /// reads downstream as gone. A backend that could not reach its hypervisor
    /// is in no position to make that claim and must return nil. Callers must
    /// preserve that unknown or provide an authoritative fallback, never
    /// silently coerce it to empty.
    ///
    /// Backends holding their VM set in memory always know, and always answer.
    /// - Returns: VM identifiers, or nil if this backend cannot say
    func listVMs() async -> [String]?

    /// Returns the console access points for a VM, or nil if none exist yet
    /// (e.g. the VM is not running).
    /// - Parameter vmId: The VM identifier
    /// - Throws: `HypervisorServiceError.notSupported` if this backend has no
    ///   console mechanism at all
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint?

    /// Attaches a disk to a running VM (hot-plug)
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   hot-plug disks
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws

    /// Detaches a disk from a running VM (hot-unplug)
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   hot-unplug disks
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws

    /// Adds one prepared network device to a QEMU VM. Active domains receive
    /// the device live and in their stored definition; inactive domains update
    /// configuration only.
    func attachNetworkInterface(
        vmId: String, spec: NetworkSpec, attachment: ResolvedNetworkAttachment
    ) async throws

    /// Removes the network device identified by the interface's stable MAC.
    func detachNetworkInterface(vmId: String, spec: NetworkSpec) async throws

    /// Converges a running VM's vCPU count and memory size on `spec`
    /// (issue #568), within the headroom the VM was created with. Growth
    /// applies online; anything the backend cannot do without a restart is
    /// left for the next boot, which uses the spec wholesale.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   resize a running VM at all
    func resizeVM(vmId: String, spec: VMSpec) async throws

    /// Sum of vCPUs and memory (in bytes) committed to VMs this service
    /// manages, or nil if it cannot say (STR-196).
    ///
    /// Used to compute available-resource figures for the scheduler, which is
    /// why `(0, 0)` is reserved for a backend that really is idle rather than
    /// spent on one that failed to find out: under-reporting reservations
    /// advertises capacity this host does not have. STR-190 is what that costs
    /// — a libvirt decoder that never once worked reported the same figure an
    /// idle host does, and the node advertised its whole machine as free while
    /// running VMs. Nil is how a backend says it cannot say, and the agent
    /// answers it by substituting the sizing from its durable manifest.
    ///
    /// Backends holding their VM set in memory always know, and always answer.
    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64)?

    /// The same committed reservation together with the exact workload IDs
    /// that produced it, when the backend can provide them atomically. Agent
    /// admission uses membership to keep a manifest orphan reserved when its
    /// daemon-side workload has disappeared.
    func reservationInventory() async -> HypervisorReservationInventory?

    /// Re-adopts a VM whose hypervisor process survived an agent restart
    /// (reconciliation phase 2, issue #260): reconnects the control session
    /// and returns the VM's observed status. Backends without a reattachable
    /// session throw `HypervisorServiceError.notSupported`, in which case the
    /// VM stays orphaned.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus

    /// Checkpoints a VM (issue #564): guest RAM, device state, and disk
    /// contents captured at one consistent point under `snapshotId`, with the
    /// VM left running.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend has no
    ///   full-VM checkpoint mechanism, or if the VM's storage cannot hold one
    func checkpointVM(vmId: String, snapshotId: String) async throws -> VMCheckpointReport

    /// Restores a VM in place from one of its checkpoints and resumes it. Same
    /// VM, same identity — it keeps its ID, disks, NICs, and addresses.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   restore checkpoints
    func restoreVM(vmId: String, snapshotId: String) async throws

    /// Removes a checkpoint's stored state. Idempotent: a checkpoint that is
    /// already gone is a success, so a retried delete converges.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   take checkpoints in the first place
    func deleteVMCheckpoint(vmId: String, snapshotId: String) async throws

    /// Whether this backend currently holds a live control session for the VM
    /// — a hypervisor process it can issue hot-plug against (STR-148).
    ///
    /// False for a VM that exists but is powered off, and for an orphan whose
    /// session has not been reattached. The volume reconciler uses it to decide
    /// whether an attachment needs a QMP round trip or is already realized by
    /// having been recorded, since the spawn path rebuilds a VM's disk set from
    /// the recorded volumes.
    func hasLiveSession(vmId: String) async -> Bool

    /// Whether this backend has any guest-observation channel at all.
    ///
    /// A pure short-circuit for the slow-poll loop, which has to establish that
    /// a VM is *running* before probing it — and that costs a status round trip
    /// per VM. Spending one every 30 seconds on a backend that can only answer
    /// nil is waste that scales with the host's VM count, so a backend which
    /// implements neither method below says so once instead.
    ///
    /// `nonisolated` because it is a property of the backend, not of its state:
    /// hopping onto a driver's actor to ask whether it is worth talking to
    /// would queue behind the very work this exists to avoid.
    nonisolated var observesGuests: Bool { get }

    /// Transitions this backend pushes as they happen, or nil for a backend
    /// that can only be polled (STR-135).
    ///
    /// An accelerant, never a source of truth: what arrives here schedules an
    /// observed-state report, and that report re-reads the host exactly as the
    /// periodic one does. So a backend is free to drop events under load, and
    /// the agent is free to coalesce them — the 20-second sync remains the
    /// correctness backstop either way.
    ///
    /// `nonisolated` for the same reason as `observesGuests`: it is a property
    /// of the backend, not of its state, and the agent attaches to it once at
    /// start. Nil rather than an empty stream so "this backend has nothing to
    /// say" is distinguishable at the point the pump is created, and no task is
    /// spawned for a backend that would never yield.
    nonisolated var lifecycleChanges: AsyncStream<VMLifecycleChange>? { get }

    /// Begin pushing into `lifecycleChanges`. Idempotent, and never throws: a
    /// backend that cannot reach its hypervisor right now retries on its own,
    /// because a subscription failing is not a reason to fail agent startup.
    func startObservingLifecycle() async

    /// Stop, releasing whatever the backend registered with its hypervisor and
    /// finishing the stream. Called from `Agent.stop()`, which is the only
    /// scope in which a subscription could otherwise outlive its purpose.
    ///
    /// Scoped to the subscription and nothing else — a backend that wants to
    /// release a connection has `shutdown()` for that, so this stays safe to
    /// call for its stated purpose alone.
    func stopObservingLifecycle() async

    /// Release whatever this backend holds open, because the agent is going
    /// away.
    ///
    /// Separate from `stopObservingLifecycle` because they are different
    /// questions with different scopes: one ends a subscription, this ends the
    /// backend. A driver whose connection is durable — `LibvirtService` holds
    /// one shared RPC connection every call path uses — has no other hook to
    /// close it on, and closing it from the subscription's teardown would make
    /// "stop observing" quietly mean "stop everything".
    func shutdown() async

    /// What the guest agent reports about itself — hostname and configured
    /// interfaces (issue #563).
    ///
    /// A backend requirement rather than a concrete driver's method because the
    /// guest-agent channel is a property of the *guest*, not of who launched
    /// it. Reading it through a downcast to one concrete driver made the whole
    /// observation invisible to every other backend.
    ///
    /// Nil is the normal "no usable channel" answer — a VM this backend does
    /// not manage, one with no agent socket, or a guest that did not respond
    /// within its budget — never an error, since nothing converges on it.
    func guestInfo(vmId: String) async -> GuestInfo?

    /// Guest memory usage from the VM's balloon device (issue #567), on the
    /// same terms as `guestInfo`: nil means "no stats", never "no memory used".
    func memoryStats(vmId: String) async -> VMMemoryStats?
}

// MARK: - Default Implementations

public extension HypervisorService {
    func attachNetworkInterface(
        vmId: String, spec: NetworkSpec, attachment: ResolvedNetworkAttachment
    ) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support VM network hot-plug")
    }

    func detachNetworkInterface(vmId: String, spec: NetworkSpec) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support VM network hot-unplug")
    }

    /// In-memory backends expose only an aggregate. Their orphan entries are
    /// outside that aggregate, so unknown membership deliberately makes the
    /// agent retain every orphan's manifest reservation.
    func reservationInventory() async -> HypervisorReservationInventory? {
        guard let reserved = await reservedResources() else { return nil }
        return HypervisorReservationInventory(
            reservation: HostReservation(cpus: reserved.vcpus, memoryBytes: reserved.memoryBytes))
    }

    /// Backends must opt in to online resize; without an explicit
    /// implementation a sizing change waits for the VM's next boot.
    func resizeVM(vmId: String, spec: VMSpec) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support resizing a running VM")
    }

    /// Backends must opt in to orphan re-adoption; without an explicit
    /// implementation an orphan cannot be reattached.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support re-adopting orphaned VMs")
    }

    /// Backends that cannot hot-plug report no live session, so the volume
    /// reconciler records the attachment and lets the next boot realize it.
    func hasLiveSession(vmId: String) async -> Bool { false }

    /// Backends opt in to guest observation, and the default agrees with the
    /// two defaults below: a backend that reports nothing is not asked.
    nonisolated var observesGuests: Bool { false }

    /// Backends opt in to pushing lifecycle transitions. Nil is not a
    /// degradation: it is how every backend behaved before STR-135, and the
    /// periodic sync it falls back to is the same backstop the opted-in ones
    /// still rely on.
    nonisolated var lifecycleChanges: AsyncStream<VMLifecycleChange>? { nil }
    func startObservingLifecycle() async {}
    func stopObservingLifecycle() async {}

    /// Backends whose resources are per-VM rather than per-driver — every one
    /// but `LibvirtService` today — have nothing to release when the agent
    /// exits.
    func shutdown() async {}

    /// Backends with no guest-agent channel (Firecracker, the mock) report
    /// nothing rather than an error: guest observation is informational, and
    /// nothing keys convergence or scheduling on it.
    func guestInfo(vmId: String) async -> GuestInfo? { nil }

    /// Likewise for balloon statistics, which need a virtio-balloon device the
    /// backend may not attach at all.
    func memoryStats(vmId: String) async -> VMMemoryStats? { nil }

    /// Backends that rebuild a VM from its spec on every spawn (rather than
    /// from a stored configuration) need nothing before a boot: a spawn that
    /// reads the spec has no stored ceiling to widen.
    func redefineVM(vmId: String, spec: VMSpec) async throws {}

    func ensureMemoryCeiling(vmId: String, spec: VMSpec) async throws {}

    /// Backends must opt in to full-VM checkpoints (issue #564). Without an
    /// explicit implementation the control plane's capability gate keeps the
    /// request away in the first place; this default is the belt-and-braces
    /// answer for one that arrives anyway.
    func checkpointVM(vmId: String, snapshotId: String) async throws -> VMCheckpointReport {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support full-VM checkpoints")
    }

    func restoreVM(vmId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support restoring full-VM checkpoints")
    }

    func deleteVMCheckpoint(vmId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support full-VM checkpoints")
    }

    /// Stops and deletes a VM
    func stopAndDeleteVM(vmId: String) async throws {
        do {
            try await shutdownVM(vmId: vmId)
            // Wait for graceful shutdown
            try await Task.sleep(for: .seconds(2))
        } catch {
            // Continue with deletion even if shutdown fails
        }
        try await deleteVM(vmId: vmId)
    }
}
