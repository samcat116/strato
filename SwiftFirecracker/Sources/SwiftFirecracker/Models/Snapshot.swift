import Foundation

/// Request body for `PUT /snapshot/create`.
///
/// A snapshot captures the guest memory and the VMM/device state (`vmstate`)
/// of a **paused** microVM. It does NOT capture the disk contents — a
/// consistent checkpoint additionally needs the caller to copy the drive
/// files while the VM is paused. Snapshots are tied to the Firecracker
/// version, host CPU, and device topology they were taken with.
public struct SnapshotCreateConfig: Codable, Sendable {
    /// Where Firecracker writes the vmstate file. Interpreted by the
    /// Firecracker process — inside its chroot for a jailed VM.
    let snapshotPath: String

    /// Where Firecracker writes the guest memory file.
    let memFilePath: String

    /// Strato only creates full snapshots. Differential snapshots require an
    /// end-to-end checkpoint policy before they belong in this package.
    let snapshotType = "Full"

    enum CodingKeys: String, CodingKey {
        case snapshotPath = "snapshot_path"
        case memFilePath = "mem_file_path"
        case snapshotType = "snapshot_type"
    }

    public init(snapshotPath: String, memFilePath: String) {
        self.snapshotPath = snapshotPath
        self.memFilePath = memFilePath
    }
}

/// Request body for `PUT /snapshot/load`.
///
/// Loading is only valid on a freshly spawned, entirely unconfigured
/// Firecracker process; the snapshot carries the full device topology, so
/// none of the usual configuration calls precede it.
public struct SnapshotLoadConfig: Codable, Sendable {
    /// The file-backed memory source used by every current restore path.
    struct MemoryBackend: Codable, Sendable {
        let backendType = "File"
        let backendPath: String

        enum CodingKeys: String, CodingKey {
            case backendType = "backend_type"
            case backendPath = "backend_path"
        }

        init(backendPath: String) {
            self.backendPath = backendPath
        }
    }

    /// Repoints one restored network interface at a different host TAP.
    ///
    /// A snapshot's vmstate records each `net` device's backing device *by
    /// name*, and Firecracker will not add, drop, or rename devices on load —
    /// so a checkpoint restored anywhere its original TAP does not exist (a
    /// fork into a new sandbox, a warm template restored into a real one)
    /// needs the mapping supplied here. `ifaceId` is the id the device was
    /// configured with (`PUT /network-interfaces/{id}`), not the guest's
    /// interface name.
    ///
    /// Requires Firecracker **1.12.0 or newer**; older builds reject the
    /// unknown field, which is why the array is omitted entirely when there is
    /// nothing to remap.
    public struct NetworkOverride: Codable, Sendable {
        /// The configured id of the interface to repoint.
        let ifaceId: String
        /// The host TAP the restored device should open instead.
        let hostDevName: String

        enum CodingKeys: String, CodingKey {
            case ifaceId = "iface_id"
            case hostDevName = "host_dev_name"
        }

        public init(ifaceId: String, hostDevName: String) {
            self.ifaceId = ifaceId
            self.hostDevName = hostDevName
        }
    }

    /// The vmstate file written by snapshot create.
    let snapshotPath: String

    let memBackend: MemoryBackend

    /// Resume the guest immediately after loading instead of leaving it
    /// paused.
    let resumeVM: Bool?

    /// Per-interface host TAP remappings, or nil to open every device under
    /// the name the snapshot recorded. Nil and `[]` are deliberately different
    /// on the wire: only nil omits the key, which is what keeps loads that
    /// remap nothing byte-identical for a pre-1.12 Firecracker.
    let networkOverrides: [NetworkOverride]?

    enum CodingKeys: String, CodingKey {
        case snapshotPath = "snapshot_path"
        case memBackend = "mem_backend"
        case resumeVM = "resume_vm"
        case networkOverrides = "network_overrides"
    }

    /// The common file-backed load: memory from `memFilePath`, optionally
    /// resuming immediately.
    public init(
        snapshotPath: String, memFilePath: String, resumeVM: Bool? = nil,
        networkOverrides: [NetworkOverride]? = nil
    ) {
        self.snapshotPath = snapshotPath
        self.memBackend = MemoryBackend(backendPath: memFilePath)
        self.resumeVM = resumeVM
        self.networkOverrides = networkOverrides
    }
}
