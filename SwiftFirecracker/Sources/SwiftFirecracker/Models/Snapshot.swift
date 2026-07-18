import Foundation

/// Request body for `PUT /snapshot/create`.
///
/// A snapshot captures the guest memory and the VMM/device state (`vmstate`)
/// of a **paused** microVM. It does NOT capture the disk contents — a
/// consistent checkpoint additionally needs the caller to copy the drive
/// files while the VM is paused. Snapshots are tied to the Firecracker
/// version, host CPU, and device topology they were taken with.
public struct SnapshotCreateConfig: Codable, Sendable {
    public enum SnapshotType: String, Codable, Sendable {
        /// The complete guest memory.
        case full = "Full"
        /// Only pages dirtied since the last snapshot; requires
        /// `track_dirty_pages` to have been enabled in the machine config.
        case diff = "Diff"
    }

    /// Where Firecracker writes the vmstate file. Interpreted by the
    /// Firecracker process — inside its chroot for a jailed VM.
    public let snapshotPath: String

    /// Where Firecracker writes the guest memory file.
    public let memFilePath: String

    /// Defaults to `Full` when omitted.
    public let snapshotType: SnapshotType?

    enum CodingKeys: String, CodingKey {
        case snapshotPath = "snapshot_path"
        case memFilePath = "mem_file_path"
        case snapshotType = "snapshot_type"
    }

    public init(snapshotPath: String, memFilePath: String, snapshotType: SnapshotType? = nil) {
        self.snapshotPath = snapshotPath
        self.memFilePath = memFilePath
        self.snapshotType = snapshotType
    }
}

/// Request body for `PUT /snapshot/load`.
///
/// Loading is only valid on a freshly spawned, entirely unconfigured
/// Firecracker process; the snapshot carries the full device topology, so
/// none of the usual configuration calls precede it.
public struct SnapshotLoadConfig: Codable, Sendable {
    /// The memory backend for the restored guest.
    public struct MemoryBackend: Codable, Sendable {
        public enum BackendType: String, Codable, Sendable {
            /// Load guest memory from a plain file.
            case file = "File"
            /// Serve guest memory on demand over userfaultfd (the caller
            /// runs the page-fault handler process).
            case uffd = "Uffd"
        }

        public let backendType: BackendType
        /// The memory file path (`file`) or the UFFD control socket (`uffd`).
        public let backendPath: String

        enum CodingKeys: String, CodingKey {
            case backendType = "backend_type"
            case backendPath = "backend_path"
        }

        public init(backendType: BackendType, backendPath: String) {
            self.backendType = backendType
            self.backendPath = backendPath
        }
    }

    /// The vmstate file written by snapshot create.
    public let snapshotPath: String

    public let memBackend: MemoryBackend

    /// Re-enable dirty page tracking on the restored VM so it can take diff
    /// snapshots of its own.
    public let enableDiffSnapshots: Bool?

    /// Resume the guest immediately after loading instead of leaving it
    /// paused.
    public let resumeVM: Bool?

    enum CodingKeys: String, CodingKey {
        case snapshotPath = "snapshot_path"
        case memBackend = "mem_backend"
        case enableDiffSnapshots = "enable_diff_snapshots"
        case resumeVM = "resume_vm"
    }

    public init(
        snapshotPath: String,
        memBackend: MemoryBackend,
        enableDiffSnapshots: Bool? = nil,
        resumeVM: Bool? = nil
    ) {
        self.snapshotPath = snapshotPath
        self.memBackend = memBackend
        self.enableDiffSnapshots = enableDiffSnapshots
        self.resumeVM = resumeVM
    }

    /// The common file-backed load: memory from `memFilePath`, optionally
    /// resuming immediately.
    public init(snapshotPath: String, memFilePath: String, resumeVM: Bool? = nil) {
        self.init(
            snapshotPath: snapshotPath,
            memBackend: MemoryBackend(backendType: .file, backendPath: memFilePath),
            resumeVM: resumeVM)
    }
}

/// Request body for `PATCH /machine-config`: a partial update over the
/// current machine configuration. Only valid before boot; the primary use is
/// flipping `track_dirty_pages` on a machine configured elsewhere.
public struct MachineConfigUpdate: Codable, Sendable {
    public let vcpuCount: Int?
    public let memSizeMib: Int?
    public let smt: Bool?
    public let trackDirtyPages: Bool?
    public let cpuTemplate: String?

    enum CodingKeys: String, CodingKey {
        case vcpuCount = "vcpu_count"
        case memSizeMib = "mem_size_mib"
        case smt
        case trackDirtyPages = "track_dirty_pages"
        case cpuTemplate = "cpu_template"
    }

    public init(
        vcpuCount: Int? = nil,
        memSizeMib: Int? = nil,
        smt: Bool? = nil,
        trackDirtyPages: Bool? = nil,
        cpuTemplate: String? = nil
    ) {
        self.vcpuCount = vcpuCount
        self.memSizeMib = memSizeMib
        self.smt = smt
        self.trackDirtyPages = trackDirtyPages
        self.cpuTemplate = cpuTemplate
    }
}

/// Request body for `PUT /entropy`: attaches a virtio-rng entropy device so
/// the guest can reseed its RNG — required for clone safety when the same
/// snapshot is restored more than once. Must be configured before boot, and
/// requires Firecracker >= 1.3.
public struct EntropyDevice: Codable, Sendable {
    /// Optional token-bucket rate limit on entropy requests.
    public struct RateLimiter: Codable, Sendable {
        public struct TokenBucket: Codable, Sendable {
            public let size: Int64
            public let oneTimeBurst: Int64?
            public let refillTime: Int64

            enum CodingKeys: String, CodingKey {
                case size
                case oneTimeBurst = "one_time_burst"
                case refillTime = "refill_time"
            }

            public init(size: Int64, oneTimeBurst: Int64? = nil, refillTime: Int64) {
                self.size = size
                self.oneTimeBurst = oneTimeBurst
                self.refillTime = refillTime
            }
        }

        public let bandwidth: TokenBucket?

        public init(bandwidth: TokenBucket? = nil) {
            self.bandwidth = bandwidth
        }
    }

    public let rateLimiter: RateLimiter?

    enum CodingKeys: String, CodingKey {
        case rateLimiter = "rate_limiter"
    }

    public init(rateLimiter: RateLimiter? = nil) {
        self.rateLimiter = rateLimiter
    }
}
