import Fluent
import Vapor
import Foundation
import StratoShared

/// Represents the format of a VM disk image.
///
/// Agents never convert *from* this value — `materializeDisk` re-detects the
/// source format with `qemu-img info` — so these cases describe what we store
/// and show, not what the hypervisor is handed. qemu-img reads all of them.
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case qcow2 = "qcow2"
    case raw = "raw"
    case vmdk = "vmdk"
    case vhd = "vhd"
    case vhdx = "vhdx"
}

/// Represents the status of an image during its lifecycle
public enum ImageStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"  // Initial state, waiting for upload/fetch
    case uploading = "uploading"  // File is being uploaded
    case downloading = "downloading"  // File is being fetched from URL
    case validating = "validating"  // File is being validated (format, checksum)
    case ready = "ready"  // Image is ready for use
    case error = "error"  // An error occurred
}

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class Image: Model, @unchecked Sendable {
    static let schema = "images"

    @ID(key: .id)
    var id: UUID?

    // Basic metadata
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Project ownership
    @Parent(key: "project_id")
    var project: Project

    /// Guest CPU architecture. Authoritative for scheduling — the scheduler reads
    /// this single value rather than reconciling per-artifact architectures.
    @Enum(key: "architecture")
    var architecture: CPUArchitecture

    /// Typed artifact set backing this image (disk-image, kernel, rootfs, ...).
    /// Must be eager-loaded (`.with(\.$artifacts)`) before calling
    /// `compatibleHypervisors()` / `isUsable(by:)` or building `ImageInfo`.
    @Children(for: \.$image)
    var artifacts: [ImageArtifact]

    // Status tracking
    @Enum(key: "status")
    var status: ImageStatus

    // Default VM configuration (optional)
    @OptionalField(key: "default_cpu")
    var defaultCpu: Int?

    @OptionalField(key: "default_memory")
    var defaultMemory: Int64?

    @OptionalField(key: "default_disk")
    var defaultDisk: Int64?

    @OptionalField(key: "default_cmdline")
    var defaultCmdline: String?

    // Upload tracking
    @Parent(key: "uploaded_by_id")
    var uploadedBy: User

    // Timestamps
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        projectID: UUID,
        architecture: CPUArchitecture = .x86_64,
        status: ImageStatus = .pending,
        uploadedByID: UUID,
        defaultCpu: Int? = nil,
        defaultMemory: Int64? = nil,
        defaultDisk: Int64? = nil,
        defaultCmdline: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$project.id = projectID
        self.architecture = architecture
        self.status = status
        self.$uploadedBy.id = uploadedByID
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.defaultDisk = defaultDisk
        self.defaultCmdline = defaultCmdline
    }
}

extension Image: Content {}

// MARK: - Computed Properties

extension Image {
    /// The disk artifact that backs the API's historical single-file convenience
    /// fields. Those fields remain useful to callers, but are never persisted on
    /// the image row.
    var diskArtifact: ImageArtifact? {
        ($artifacts.value ?? []).first { $0.kind == .diskImage }
    }

    /// The disk artifact that is complete and architecture-compatible enough
    /// to seed a managed volume.
    var usableDiskArtifact: ImageArtifact? {
        diskArtifact.flatMap { artifact in
            artifact.architecture == architecture && artifact.isUsable ? artifact : nil
        }
    }

    /// The artifact whose state explains the aggregate image lifecycle.
    /// Falls back to the disk convenience projection outside active/error
    /// states so existing single-disk API fields retain their meaning.
    var lifecycleArtifact: ImageArtifact? {
        let artifacts = $artifacts.value ?? []
        switch status {
        case .downloading:
            return artifacts.first { $0.status == .downloading }
        case .error:
            return artifacts.first { $0.status == .error }
        default:
            return diskArtifact
        }
    }

    // MARK: - Hypervisor Compatibility

    /// The hypervisor types that can run this image, derived from the artifact
    /// set and the image architecture.
    ///
    /// - QEMU needs a bootable `diskImage` (of matching arch).
    /// - Firecracker needs a `kernel` + `rootfs` pair (of matching arch);
    ///   `initramfs` is optional.
    ///
    /// Requires `$artifacts` to be eager-loaded; an image with no loaded
    /// artifacts is compatible with nothing.
    func compatibleHypervisors() -> Set<HypervisorType> {
        // `$artifacts.value` is nil when the relation isn't eager-loaded, which
        // reads as "no known artifacts" rather than crashing on access. Only
        // `.ready` artifacts count — a still-downloading rootfs must not make the
        // image look bootable (or get sent to an agent).
        let loaded = $artifacts.value ?? []
        let matching = loaded.filter { $0.architecture == architecture && $0.isUsable }
        let kinds = Set(matching.map(\.kind))

        var result: Set<HypervisorType> = []
        if kinds.contains(.diskImage) {
            result.insert(.qemu)
        }
        if kinds.contains(.kernel) && kinds.contains(.rootfs) {
            result.insert(.firecracker)
        }
        return result
    }

    /// Whether this image can be run by the given hypervisor type. Requires
    /// `$artifacts` to be eager-loaded.
    func isUsable(by hypervisorType: HypervisorType) -> Bool {
        compatibleHypervisors().contains(hypervisorType)
    }

    /// Recompute the aggregate image status from the authoritative artifact
    /// rows. A complete bootable set wins even when an optional artifact failed;
    /// otherwise expose the most actionable in-progress/error state.
    func recomputeStatus(on database: any Database) async throws {
        try await $artifacts.load(on: database)
        let loaded = $artifacts.value ?? []

        let newStatus: ImageStatus
        if !compatibleHypervisors().isEmpty {
            newStatus = .ready
        } else if loaded.contains(where: { $0.status == .error }) {
            newStatus = .error
        } else if loaded.contains(where: { $0.status == .downloading }) {
            newStatus = .downloading
        } else {
            newStatus = .pending
        }

        if status != newStatus {
            status = newStatus
            try await save(on: database)
        }
    }
}

// MARK: - Request/Response DTOs

struct CreateImageRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?
    let sourceURL: String?
    let architecture: CPUArchitecture?
    /// Optional SHA-256 (64 hex chars) the downloaded image must match.
    let checksum: String?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?

    // Explicit initializer so `architecture` (and the other optionals) can be
    // omitted by callers; JSON decoding is unaffected (Codable is still synthesized).
    init(
        name: String,
        description: String? = nil,
        sourceURL: String? = nil,
        architecture: CPUArchitecture? = nil,
        checksum: String? = nil,
        defaultCpu: Int? = nil,
        defaultMemory: Int64? = nil,
        defaultDisk: Int64? = nil,
        defaultCmdline: String? = nil
    ) {
        self.name = name
        self.description = description
        self.sourceURL = sourceURL
        self.architecture = architecture
        self.checksum = checksum
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.defaultDisk = defaultDisk
        self.defaultCmdline = defaultCmdline
    }

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
        // The same ceiling `VMController` holds a request's own `cmdline` to.
        // An image's default is nobody's to fix at VM-create time, which is
        // exactly why it has to be bounded where it is authored.
        try Validate.text(defaultCmdline, "defaultCmdline")
    }
}

struct UpdateImageRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?
    let architecture: CPUArchitecture?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?

    init(
        name: String? = nil,
        description: String? = nil,
        architecture: CPUArchitecture? = nil,
        defaultCpu: Int? = nil,
        defaultMemory: Int64? = nil,
        defaultDisk: Int64? = nil,
        defaultCmdline: String? = nil
    ) {
        self.name = name
        self.description = description
        self.architecture = architecture
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.defaultDisk = defaultDisk
        self.defaultCmdline = defaultCmdline
    }

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
        try Validate.text(defaultCmdline, "defaultCmdline")
    }
}

struct ImageResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let projectId: UUID?
    let filename: String?
    let size: Int64?
    let sizeFormatted: String?
    let format: ImageFormat?
    let architecture: CPUArchitecture
    let checksum: String?
    let status: ImageStatus
    let sourceURL: String?
    let downloadProgress: Int?
    let errorMessage: String?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?
    /// Typed artifacts, when eager-loaded; empty otherwise.
    let artifacts: [ImageArtifact.Public]
    /// Hypervisor types this image can run on, when artifacts are eager-loaded.
    let compatibleHypervisors: [HypervisorType]
    let uploadedById: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from image: Image) {
        self.id = image.id
        self.name = image.name
        self.description = image.description
        self.projectId = image.$project.id
        let diskArtifact = image.diskArtifact
        self.filename = diskArtifact?.filename
        self.size = diskArtifact?.size
        self.sizeFormatted = diskArtifact?.size.formattedByteSize
        self.format = diskArtifact?.format
        self.architecture = image.architecture
        self.checksum = diskArtifact?.checksum
        self.status = image.status
        self.sourceURL = diskArtifact?.sourceURL
        self.downloadProgress = image.lifecycleArtifact?.downloadProgress
        self.errorMessage = image.lifecycleArtifact?.errorMessage
        self.defaultCpu = image.defaultCpu
        self.defaultMemory = image.defaultMemory
        self.defaultDisk = image.defaultDisk
        self.defaultCmdline = image.defaultCmdline
        self.artifacts = (image.$artifacts.value ?? []).map { $0.asPublic() }
        self.compatibleHypervisors = image.compatibleHypervisors().sorted { $0.rawValue < $1.rawValue }
        self.uploadedById = image.$uploadedBy.id
        self.createdAt = image.createdAt
        self.updatedAt = image.updatedAt
    }
}

struct ImageStatusResponse: Content {
    let id: UUID
    let status: ImageStatus
    let downloadProgress: Int?
    let errorMessage: String?
    let size: Int64?
    let checksum: String?

    init(from image: Image) {
        self.id = image.id ?? UUID()
        self.status = image.status
        let diskArtifact = image.diskArtifact
        self.downloadProgress = image.lifecycleArtifact?.downloadProgress
        self.errorMessage = image.lifecycleArtifact?.errorMessage
        self.size = diskArtifact?.size
        self.checksum = diskArtifact?.checksum
    }
}

// MARK: - Errors

enum ImageError: Error, LocalizedError, Sendable {
    case imageNotFound(UUID)
    case imageNotReady(UUID)
    case invalidFormat(String)
    case uploadFailed(String)
    case downloadFailed(String)
    case checksumMismatch
    case storageFailed(String)
    case fileTooLarge(Int64, Int64)  // actual, max

    var errorDescription: String? {
        switch self {
        case .imageNotFound(let id):
            return "Image '\(id)' not found."
        case .imageNotReady(let id):
            return "Image '\(id)' is not ready for use."
        case .invalidFormat(let reason):
            return "Invalid image format: \(reason)"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .checksumMismatch:
            return "Image checksum verification failed."
        case .storageFailed(let reason):
            return "Storage operation failed: \(reason)"
        case .fileTooLarge(let actual, let max):
            return "File size \(actual) bytes exceeds maximum allowed \(max) bytes."
        }
    }
}
