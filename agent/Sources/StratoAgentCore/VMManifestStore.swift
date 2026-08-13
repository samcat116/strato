import Foundation
import Logging
import StratoShared

/// One workload's entry in the agent-wide manifest: which backend owns it and
/// the spec it was created from (the spec carries the resource reservations
/// that must survive a restart).
///
/// Issue #417 generalized the manifest over `WorkloadKind` so sandbox orphans
/// are detected on restart, keep their resources reserved, and can be
/// re-adopted, exactly like VMs.
public struct VMManifestEntry: Codable, Sendable {
    public let kind: WorkloadKind
    public let hypervisorType: HypervisorType
    /// Creation spec and resource reservation. For sandbox entries this is a
    /// reservation-only projection of `sandboxSpec` (cpus/memory), so
    /// restart-survival capacity accounting reads one shape for both kinds.
    ///
    /// `var` only so `with(spec:)` can rewrite it in place; every caller goes
    /// through that method rather than assigning here.
    public private(set) var spec: VMSpec
    /// The QEMU domain's realized, fixed memory reservation. This is persisted
    /// separately from `spec`: a live resize changes the guest grant but does
    /// not resize the virtio-mem region the process was created with.
    ///
    /// Nil for non-QEMU workloads and entries written before this field
    /// existed. Admission treats a legacy nil conservatively as the full
    /// requested `maxMemoryBytes`, because the exact aligned region can no
    /// longer be reconstructed after a live resize.
    public private(set) var realizedMemoryReservationBytes: Int64?
    /// The sandbox's own spec (present iff `kind == .sandbox`), kept so the
    /// sandbox runtime can re-adopt the orphan after a restart.
    public let sandboxSpec: SandboxSpec?
    /// This VM's context ID in the host's vsock namespace (STR-72), nil for a
    /// workload that draws no CID from it — every sandbox, every Firecracker
    /// VM, and any VM created before the allocator existed.
    ///
    /// It lives here because the namespace is host-global and the manifest is
    /// the only durable record of what this host is running: a restarted agent
    /// that forgot its assignments would hand a live VM's CID to a new one,
    /// which is two guests on one control channel rather than a lost number.
    /// See ``VsockCIDAllocator``.
    public let vsockCID: UInt32?
    /// The edge nonces this host has already applied for the workload — the
    /// last reboot and the last restore (ADR 0001 stage 9, STR-151).
    ///
    /// **Nonce durability is the correctness invariant of that stage**, and this
    /// field is where it lives, for the reason `vsockCID` does: the manifest is
    /// the agent's only memory across a restart. A generation is idempotent, so
    /// the reconciler's in-process `lastApplied` may reset with the process for
    /// free — re-converging a state that already holds does nothing. An edge is
    /// not: re-driving one reboots a guest a second time, or rewinds it to a
    /// checkpoint it has been writing past.
    ///
    /// Optional, and `nil` means "no record", never "applied nothing". An entry
    /// written by a build older than this field decodes to nil, and a nil is
    /// *adopted* — the desired nonces are written down without being performed —
    /// so a manifest-less re-registration cannot replay a VM's whole reboot
    /// history. See `AppliedEdgeNonces`.
    public var appliedEdges: AppliedEdgeNonces?
    /// Whether this agent has applied Firecracker's pre-boot MMDS interface
    /// allow-list to the VMM represented by this entry.
    ///
    /// Nil identifies manifests written before STR-67. That distinction is
    /// required during adoption: the surviving process has the same network
    /// spec as desired state, but no `/mmds/config`, and Firecracker exposes no
    /// post-boot repair path. The agent recreates that VMM once, then records
    /// true. Non-Firecracker VMs and sandboxes leave this nil.
    public private(set) var firecrackerMMDSPolicyApplied: Bool?
    /// Exact Firecracker interface ids admitted to MMDS by the represented
    /// VMM. Unlike `spec.networks`, this includes the per-VM metadata kill
    /// switch as well as per-network policy, so a metadata-only desired-state
    /// update remains observable after an agent restart.
    ///
    /// Nil is the compatibility shape written before this policy was recorded
    /// exactly. A marked STR-67 entry then falls back to the network list,
    /// matching what those builds configured.
    public private(set) var firecrackerMMDSInterfaces: [String]?

    public init(
        hypervisorType: HypervisorType,
        spec: VMSpec,
        realizedMemoryReservationBytes: Int64? = nil,
        vsockCID: UInt32? = nil,
        appliedEdges: AppliedEdgeNonces? = nil,
        firecrackerMMDSPolicyApplied: Bool? = nil,
        firecrackerMMDSInterfaces: [String]? = nil
    ) {
        self.kind = .vm
        self.hypervisorType = hypervisorType
        self.spec = spec
        self.realizedMemoryReservationBytes = realizedMemoryReservationBytes.map { max(0, $0) }
        self.sandboxSpec = nil
        self.vsockCID = vsockCID
        self.appliedEdges = appliedEdges
        self.firecrackerMMDSPolicyApplied = firecrackerMMDSPolicyApplied
        self.firecrackerMMDSInterfaces = firecrackerMMDSInterfaces
    }

    /// A sandbox entry. Sandboxes boot through Firecracker only, so the
    /// backend routing field is pinned.
    public init(sandboxSpec: SandboxSpec, appliedEdges: AppliedEdgeNonces? = nil) {
        self.kind = .sandbox
        self.hypervisorType = .firecracker
        self.spec = VMSpec(
            cpus: sandboxSpec.cpus, memoryBytes: sandboxSpec.memoryBytes, boot: .disk(firmware: nil))
        self.realizedMemoryReservationBytes = nil
        self.sandboxSpec = sandboxSpec
        self.vsockCID = nil
        self.appliedEdges = appliedEdges
        self.firecrackerMMDSPolicyApplied = nil
        self.firecrackerMMDSInterfaces = nil
    }

    /// The same workload with a new spec — a resize, or a volume attached or
    /// detached.
    ///
    /// Copying rather than re-constructing is what keeps a spec change from
    /// silently dropping everything else the entry carries, and two fields have
    /// now needed exactly that. The vsock CID (STR-72) is allocated once at
    /// create and belongs to the VM for its whole life, so a resize that rebuilt
    /// the entry from `(hypervisorType, spec)` would free a running VM's CID for
    /// reuse. The edge-nonce record (STR-151) is what this host has already
    /// *done* to the workload, so dropping it would make the next sync read "no
    /// record" and quietly discard a reboot or restore the user had asked for.
    ///
    /// It mutates a copy rather than listing the fields to carry, so a field
    /// added later is preserved without anyone having to remember this method.
    public func with(spec newSpec: VMSpec) -> VMManifestEntry {
        var copy = self
        copy.spec = newSpec
        return copy
    }

    /// Records the desired spec after re-adopting a surviving VM without
    /// claiming that Firecracker's immutable MMDS allow-list changed with it.
    ///
    /// A Firecracker entry carrying the policy marker describes a VMM that was
    /// already configured from the manifest's network list. Desired state may
    /// have changed while the agent was down, but reconnecting to that process
    /// does not apply the new list. Keep the realized networks until the
    /// reconciler replaces the VMM; every other part of the desired spec can be
    /// recorded immediately. Legacy entries have no reliable realized policy,
    /// so their one-time upgrade path decides what to record instead.
    public func recordingAdoption(of desiredSpec: VMSpec) -> VMManifestEntry {
        guard hypervisorType == .firecracker, firecrackerMMDSPolicyApplied == true else {
            return with(spec: desiredSpec)
        }
        return with(spec: desiredSpec.withNetworks(spec.networks))
    }

    /// Records the exact immutable MMDS allow-list installed in the current
    /// Firecracker process.
    public func applyingFirecrackerMMDSPolicy(interfaces: [String]) -> VMManifestEntry {
        var copy = self
        copy.firecrackerMMDSPolicyApplied = true
        copy.firecrackerMMDSInterfaces = interfaces
        return copy
    }

    /// Records a domain widening without changing the grant currently applied
    /// to the guest. Domain redefinition is upward-only, so this value is too.
    public func reservingMemory(atLeast bytes: Int64) -> VMManifestEntry {
        var copy = self
        copy.realizedMemoryReservationBytes = max(copy.realizedMemoryReservationBytes ?? 0, bytes)
        return copy
    }

    /// Moves only growing reservation dimensions toward a desired spec. A boot
    /// can realize those larger grants before the planner emits its separate
    /// drift-correction resize item, while a requested shrink must not be
    /// credited until that resize succeeds.
    public func reservingPositiveSizingGrowth(toward desired: VMSpec) -> VMManifestEntry {
        var copy = self
        copy.spec = VMSpec(
            cpus: max(spec.cpus, desired.cpus),
            maxCpus: max(spec.maxCpus, desired.maxCpus),
            memoryBytes: max(spec.memoryBytes, desired.memoryBytes),
            maxMemoryBytes: max(spec.maxMemoryBytes, desired.maxMemoryBytes),
            balloonTargetBytes: spec.balloonTargetBytes,
            diskBytes: spec.diskBytes,
            sharedMemory: spec.sharedMemory,
            hugepages: spec.hugepages,
            boot: spec.boot,
            machine: spec.machine,
            guestAgentEnabled: spec.guestAgentEnabled,
            volumes: spec.volumes,
            networks: spec.networks,
            console: spec.console,
            sshAuthorizedKeys: spec.sshAuthorizedKeys,
            userData: spec.userData,
            metadataSource: spec.metadataSource)
        return copy
    }

}

/// An entry that proves a workload exists under its id but cannot be routed to
/// a backend (STR-138).
///
/// The manifest is the agent's only memory of what it is running, and it is
/// read by builds that did not write it: an agent rolled back past a new
/// hypervisor backend meets `"hypervisorType": "libvirt"`, and one rolled back
/// past a required spec field meets a `VMSpec` it cannot decode. Neither is a
/// reason to forget the workload — something is still running under that id,
/// on disks a `.create` would happily open a second writer against. So the
/// entry is kept in a degraded form that is enough for the two safety-critical
/// jobs: keep reserving the host capacity it is using, and keep the reconciler
/// from creating it again.
///
/// `raw` is the entry exactly as it was read, re-emitted verbatim by `save`.
/// Rewriting it in a shape this build understands would destroy the routing
/// information the *newer* build needs when the operator rolls forward again.
public struct QuarantinedManifestEntry: Sendable {
    /// The workload kind, when it decoded. Nil means even that is unreadable.
    public let kind: WorkloadKind?
    /// The unroutable backend identifier, verbatim, when the entry carried a
    /// string there at all.
    public let hypervisorTypeRawValue: String?
    /// Salvaged reservation. Zero when even this could not be read — an
    /// under-count, but the entry still blocks a re-create, which is the half
    /// that cannot be recovered later.
    public let cpus: Int
    public let memoryBytes: Int64
    public let diskBytes: Int64
    /// Salvaged vsock CID (STR-72). Reserved exactly like the CPU and memory
    /// above, and for a sharper reason: the workload under this entry may still
    /// be running on that CID, and the namespace is host-global, so handing it
    /// to a new VM would join two guests' control channels. Nil when the entry
    /// carried none or it could not be read — the same under-count the
    /// reservations take, and the same reason it is only an under-count: this
    /// build cannot create the workload again either way.
    public let vsockCID: UInt32?
    /// Why this entry could not be used, for the log and the operator.
    public let reason: String
    /// The entry as read, for verbatim re-persistence.
    public let raw: CodableValue

    init(
        kind: WorkloadKind?,
        hypervisorTypeRawValue: String?,
        cpus: Int,
        memoryBytes: Int64,
        diskBytes: Int64,
        vsockCID: UInt32?,
        reason: String,
        raw: CodableValue
    ) {
        self.kind = kind
        self.hypervisorTypeRawValue = hypervisorTypeRawValue
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.vsockCID = vsockCID
        self.reason = reason
        self.raw = raw
    }

    /// The kind to file this entry under. Treating an unreadable kind as a VM
    /// keeps the entry on the conservative workload path while quarantined.
    public var effectiveKind: WorkloadKind { kind ?? .vm }

    /// Recover an entry written before `VolumeSpec.volumeId` became required.
    /// This is intentionally manifest-only: the shared wire decoder remains
    /// strict. Every path-only attachment must match a managed desired volume
    /// by its historical path, or by its unique device/order identity for the
    /// Firecracker cutover whose old manifest named `disk.qcow2` while the
    /// realized rootfs lived at `rootfs.raw`.
    public func recoveringManagedVolumeIdentities(from desired: VMSpec) -> VMManifestEntry? {
        guard case .object(var entry) = raw,
            case .object(var spec)? = entry["spec"],
            case .array(var volumes)? = spec["volumes"]
        else { return nil }

        var changed = false
        for index in volumes.indices {
            guard case .object(var legacy) = volumes[index] else { continue }
            let identityIsMissing: Bool
            switch legacy["volumeId"] {
            case nil, .some(.null): identityIsMissing = true
            default: identityIsMissing = false
            }
            guard identityIsMissing else { continue }

            let legacyPath: String? =
                if case .string(let value)? = legacy["storagePath"] { value } else { nil }
            let legacyDevice: String? =
                if case .string(let value)? = legacy["deviceName"] { value } else { nil }
            let legacyOrder: Int? =
                if case .int(let value)? = legacy["bootOrder"] { value } else { nil }

            let pathMatches = desired.volumes.filter { $0.storagePath == legacyPath && legacyPath != nil }
            let identityMatches = desired.volumes.filter {
                let sameOrder =
                    $0.bootOrder == legacyOrder
                    || (legacyOrder == nil && $0.bootOrder == 0)
                return $0.deviceName.rawValue == legacyDevice && sameOrder
            }
            let matches = pathMatches.isEmpty ? identityMatches : pathMatches
            guard matches.count == 1, let managed = matches.first else { return nil }

            legacy["volumeId"] = .string(managed.volumeId.uuidString)
            legacy["storagePath"] = managed.storagePath.map(CodableValue.string) ?? .null
            volumes[index] = .object(legacy)
            changed = true
        }
        guard changed else { return nil }

        spec["volumes"] = .array(volumes)
        entry["spec"] = .object(spec)
        guard let data = try? JSONEncoder().encode(CodableValue.object(entry)) else { return nil }
        return try? JSONDecoder().decode(VMManifestEntry.self, from: data)
    }
}

/// Why the manifest could not be read, and where the evidence went.
public struct ManifestReadFailure: Sendable, Equatable {
    /// The manifest that could not be read.
    public let path: String
    public let reason: String
    /// Where the unreadable bytes were copied for post-mortem, when the copy
    /// succeeded. The original stays where it is.
    public let preservedCopyPath: String?

    init(path: String, reason: String, preservedCopyPath: String?) {
        self.path = path
        self.reason = reason
        self.preservedCopyPath = preservedCopyPath
    }
}

/// The result of reading the manifest, with "I don't know" spelled differently
/// from "there's nothing here" (STR-138).
///
/// Before this existed, `load()` returned a bare dictionary and every read
/// error returned `[:]` — an assertion that the host is idle, which capacity
/// accounting, the reconciler, and the observed-state report all act on
/// immediately. A caller now has to decide what an unreadable manifest means,
/// and the only safe answer is to stop advertising and stop converging.
public enum ManifestLoad: Sendable {
    /// No manifest: a genuinely fresh host, which is the only case that may be
    /// read as "nothing is running here".
    case fresh
    /// The manifest parsed. `entries` are routable; `quarantined` are
    /// workloads that exist but cannot be acted on.
    case loaded(entries: [String: VMManifestEntry], quarantined: [String: QuarantinedManifestEntry])
    /// The manifest exists but could not be read or parsed. The host's
    /// contents are unknown.
    case unreadable(ManifestReadFailure)
}

extension Sequence where Element == VMManifestEntry {
    /// Total disk committed across these workloads' specs. Specs from a
    /// control plane that predates `VMSpec.diskBytes` (issue #473) count as 0
    /// — under-reporting matches the old behavior rather than blocking
    /// placement. Sandbox entries carry no `diskBytes` and naturally add 0,
    /// mirroring the scheduler (sandboxes reserve no disk).
    public var totalReservedDiskBytes: Int64 {
        reduce(0) { $0 + ($1.spec.diskBytes ?? 0) }
    }
}

extension Sequence where Element == VMSpec {
    /// Total vCPUs and memory committed across these specs — the
    /// reserved-resource figures the scheduler subtracts from host capacity.
    /// One definition shared by every driver's `reservedResources()` and the
    /// agent's manifest fallback, so the summation cannot drift between them.
    public var reservedResources: (vcpus: Int, memoryBytes: Int64) {
        reduce((0, Int64(0))) { ($0.0 + $1.cpus, $0.1 + $1.memoryBytes) }
    }
}

/// Persists the set of workloads (VMs and sandboxes) an agent is managing —
/// across all backends — to disk so that, after an agent restart, the agent can
/// route operations to the right backend and keep orphaned workloads' resources
/// reserved.
///
/// On restart, previously-managed VMs are loaded from this manifest as orphans,
/// and the reconciler re-adopts them when the backend supports it (the `.adopt`
/// step in `Reconciliation.swift`): QEMU domains are looked up in libvirtd,
/// which owns them and survives the agent, and Firecracker reconnects to
/// its deterministic per-VM API socket (issue #433). Backends without adoption
/// support — e.g. the Mock hypervisor, which keeps the throwing `adoptVM`
/// default in `HypervisorProtocol.swift` — and VMs created before deterministic
/// socket paths remain orphaned; they keep their resources reserved but are
/// absent from the agent's heartbeat, which the control plane's reconciliation
/// surfaces as `.error` for operator attention.
public struct VMManifestStore {
    public let path: String
    let logger: Logger

    public init(path: String, logger: Logger) {
        self.path = path
        self.logger = logger
    }

    /// Reads the previously-persisted workload manifest.
    ///
    /// Entries are decoded **one at a time** so one bad entry costs one entry.
    /// The dictionary used to decode as a unit, which made any single
    /// undecodable entry — an unrecognized `hypervisorType` after an agent
    /// rollback, a spec field this build doesn't know — discard every other
    /// workload on the host along with it. Only a failure at the top level
    /// (unreadable bytes, truncated or non-object JSON) is `.unreadable` now.
    public func load() -> ManifestLoad {
        guard FileManager.default.fileExists(atPath: path) else { return .fresh }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return unreadable("could not be read: \(error)")
        }

        let parsed: PartiallyDecodedManifest
        do {
            parsed = try JSONDecoder().decode(PartiallyDecodedManifest.self, from: data)
        } catch {
            return unreadable("is not a readable manifest object: \(error)")
        }

        if !parsed.quarantined.isEmpty {
            logger.error(
                "Quarantining VM manifest entries this build cannot route; their capacity stays reserved and nothing may re-create them",
                metadata: [
                    "path": .string(path),
                    "quarantined": .stringConvertible(parsed.quarantined.count),
                    "readable": .stringConvertible(parsed.entries.count),
                    "workloadIds": .string(parsed.quarantined.keys.sorted().joined(separator: ",")),
                    "reasons": .string(
                        Set(parsed.quarantined.values.map(\.reason)).sorted().joined(separator: "; ")),
                ])
        }
        return .loaded(entries: parsed.entries, quarantined: parsed.quarantined)
    }

    /// Atomically writes the current manifest to disk, re-emitting any
    /// quarantined entries verbatim.
    ///
    /// Callers must not call this at all while the manifest is unreadable —
    /// the first write after a failed read is what turns a recoverable file
    /// into a permanent loss. `Agent.persistManifest()` holds that line;
    /// `preserveUnreadableManifest` is the backstop that keeps a copy anyway.
    ///
    /// - Returns: `true` when the write succeeded; failures are logged.
    @discardableResult
    public func save(
        _ manifest: [String: VMManifestEntry],
        preserving quarantined: [String: QuarantinedManifestEntry] = [:]
    ) -> Bool {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(
                MergedManifest(entries: manifest, quarantined: quarantined.mapValues(\.raw)))
            // Atomic write so a crash mid-write can't leave a truncated manifest.
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            logger.error("Failed to write VM manifest at \(path): \(error)")
            return false
        }
    }

    /// Logs an unreadable manifest, copies it aside for post-mortem, and
    /// describes the failure.
    private func unreadable(_ reason: String) -> ManifestLoad {
        let preserved = preserveUnreadableManifest()
        logger.error(
            "VM manifest is unreadable; this host's workloads are unknown and it will advertise no capacity until the manifest is repaired or removed",
            metadata: [
                "path": .string(path),
                "reason": .string(reason),
                "preservedCopy": .string(preserved ?? "none"),
            ])
        return .unreadable(
            ManifestReadFailure(path: path, reason: reason, preservedCopyPath: preserved))
    }

    /// Copies the unreadable manifest to `<path>.corrupt-<timestamp>`, leaving
    /// the original in place.
    ///
    /// A copy, not a move: the original is what a *later* build — one that
    /// understands whatever this one choked on — needs to find, and moving it
    /// aside would make the next start read the host as fresh, which is the
    /// exact confusion this whole change exists to prevent.
    ///
    /// Skipped when an identical copy is already there, so an agent that
    /// crash-loops against the same bad file leaves one copy rather than one
    /// per restart.
    private func preserveUnreadableManifest() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + Self.preservedSuffix

        let existing =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "." : directory)) ?? []
        for name in existing.sorted() where name.hasPrefix(prefix) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if (try? Data(contentsOf: URL(fileURLWithPath: candidate))) == data {
                return candidate
            }
        }

        let destination = path + Self.preservedSuffix + Self.preservationTimestamp()
        do {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            return destination
        } catch {
            logger.error("Failed to preserve unreadable VM manifest at \(destination): \(error)")
            return nil
        }
    }

    static let preservedSuffix = ".corrupt-"

    private static func preservationTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

}

// MARK: - Per-entry decoding

/// Decodes the manifest object entry by entry, so an entry this build cannot
/// read is quarantined instead of taking the whole host's record with it.
private struct PartiallyDecodedManifest: Decodable {
    var entries: [String: VMManifestEntry] = [:]
    var quarantined: [String: QuarantinedManifestEntry] = [:]

    init(from decoder: any Decoder) throws {
        // A throw here — not an object, truncated bytes — is the genuinely
        // unreadable case and is the caller's `.unreadable`.
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        for key in container.allKeys {
            if let entry = try? container.decode(VMManifestEntry.self, forKey: key) {
                entries[key.stringValue] = entry
                continue
            }
            quarantined[key.stringValue] = Self.quarantine(container, key)
        }
    }

    private static func quarantine(
        _ container: KeyedDecodingContainer<DynamicCodingKey>, _ key: DynamicCodingKey
    ) -> QuarantinedManifestEntry {
        let raw = (try? container.decode(CodableValue.self, forKey: key)) ?? .null
        let salvaged = try? container.decode(SalvagedEntry.self, forKey: key)
        let reservation = salvaged?.spec ?? salvaged?.sandboxSpec
        let hypervisorType = salvaged?.hypervisorType

        let reason: String
        if let hypervisorType, HypervisorType(rawValue: hypervisorType) == nil {
            // The rollback case: an agent downgraded past a backend it once
            // wrote here. Named precisely, because the fix is to roll forward.
            reason = "unrecognized hypervisor type \"\(hypervisorType)\""
        } else if salvaged == nil {
            reason = "entry is not a readable object"
        } else {
            reason = "entry could not be decoded by this agent build"
        }

        return QuarantinedManifestEntry(
            kind: salvaged?.kind.flatMap(WorkloadKind.init(rawValue:)),
            hypervisorTypeRawValue: hypervisorType,
            cpus: reservation?.cpus ?? 0,
            memoryBytes: reservation?.memoryBytes ?? 0,
            diskBytes: reservation?.diskBytes ?? 0,
            vsockCID: salvaged?.vsockCID,
            reason: reason,
            raw: raw
        )
    }
}

/// Everything worth salvaging from an entry this build cannot decode: what
/// backend it claims, what kind it is, and what it reserves. Every field is
/// optional and read with `try?` so one unreadable field never costs the
/// others.
private struct SalvagedEntry: Decodable {
    struct Reservation: Decodable {
        let cpus: Int?
        let memoryBytes: Int64?
        let diskBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case cpus, memoryBytes, diskBytes
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cpus = try? c.decodeIfPresent(Int.self, forKey: .cpus)
            memoryBytes = try? c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
            diskBytes = try? c.decodeIfPresent(Int64.self, forKey: .diskBytes)
        }
    }

    let kind: String?
    let hypervisorType: String?
    let spec: Reservation?
    let sandboxSpec: Reservation?
    let vsockCID: UInt32?

    enum CodingKeys: String, CodingKey {
        case kind, hypervisorType, spec, sandboxSpec, vsockCID
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        hypervisorType = try? c.decodeIfPresent(String.self, forKey: .hypervisorType)
        spec = try? c.decodeIfPresent(Reservation.self, forKey: .spec)
        sandboxSpec = try? c.decodeIfPresent(Reservation.self, forKey: .sandboxSpec)
        vsockCID = try? c.decodeIfPresent(UInt32.self, forKey: .vsockCID)
    }
}

/// The manifest as written: decodable entries encoded normally, quarantined
/// ones re-emitted byte-for-byte as they were read.
private struct MergedManifest: Encodable {
    let entries: [String: VMManifestEntry]
    let quarantined: [String: CodableValue]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (id, entry) in entries {
            try container.encode(entry, forKey: DynamicCodingKey(id))
        }
        // A live entry wins if an id somehow appears in both: the workload was
        // re-created under a build that can route it, which retires the
        // quarantine.
        for (id, raw) in quarantined where entries[id] == nil {
            try container.encode(raw, forKey: DynamicCodingKey(id))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
