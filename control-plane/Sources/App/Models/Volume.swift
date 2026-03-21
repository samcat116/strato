import Fluent
import Vapor
import Foundation

/// Represents the format of a volume disk image
public enum VolumeFormat: String, Codable, CaseIterable, Sendable {
    case qcow2 = "qcow2"
    case raw = "raw"
}

/// Represents the type of volume
public enum VolumeType: String, Codable, CaseIterable, Sendable {
    case boot = "boot"   // Boot disk for VM
    case data = "data"   // Additional data disk
}

/// Represents the status of a volume during its lifecycle
public enum VolumeStatus: String, Codable, CaseIterable, Sendable {
    case creating = "creating"         // Volume is being created
    case available = "available"       // Volume is ready and not attached
    case attaching = "attaching"       // Volume is being attached to a VM
    case attached = "attached"         // Volume is attached to a VM
    case detaching = "detaching"       // Volume is being detached from a VM
    case resizing = "resizing"         // Volume is being resized
    case snapshotting = "snapshotting" // Snapshot is being created
    case cloning = "cloning"           // Volume is being cloned
    case deleting = "deleting"         // Volume is being deleted
    case error = "error"               // An error occurred
}

final class Volume: Model, @unchecked Sendable {
    static let schema = "volumes"

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

    // Volume specifications
    @Field(key: "size")
    var size: Int64  // Size in bytes

    @Enum(key: "format")
    var format: VolumeFormat

    @Enum(key: "type")
    var volumeType: VolumeType

    // Status tracking
    @Enum(key: "status")
    var status: VolumeStatus

    @OptionalField(key: "error_message")
    var errorMessage: String?

    // Storage location
    @OptionalField(key: "storage_path")
    var storagePath: String?

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    // VM attachment (null when detached)
    @OptionalParent(key: "vm_id")
    var vm: VM?

    @OptionalField(key: "device_name")
    var deviceName: String?  // disk0, disk1, etc.

    @OptionalField(key: "boot_order")
    var bootOrder: Int?

    // Source tracking (for clones/volumes created from images)
    @OptionalParent(key: "source_image_id")
    var sourceImage: Image?

    @OptionalParent(key: "source_volume_id")
    var sourceVolume: Volume?

    // Owner tracking
    @Parent(key: "created_by_id")
    var createdBy: User

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
        size: Int64,
        format: VolumeFormat = .qcow2,
        volumeType: VolumeType = .data,
        status: VolumeStatus = .creating,
        createdByID: UUID,
        sourceImageID: UUID? = nil,
        sourceVolumeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$project.id = projectID
        self.size = size
        self.format = format
        self.volumeType = volumeType
        self.status = status
        self.$createdBy.id = createdByID
        if let sourceImageID = sourceImageID {
            self.$sourceImage.id = sourceImageID
        }
        if let sourceVolumeID = sourceVolumeID {
            self.$sourceVolume.id = sourceVolumeID
        }
    }
}

extension Volume: Content {}

// MARK: - Public DTO

extension Volume {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let projectId: UUID?
        let size: Int64
        let sizeGB: Double
        let format: VolumeFormat
        let volumeType: VolumeType
        let status: VolumeStatus
        let errorMessage: String?
        let storagePath: String?
        let hypervisorId: String?
        let vmId: UUID?
        let deviceName: String?
        let bootOrder: Int?
        let sourceImageId: UUID?
        let sourceVolumeId: UUID?
        let createdById: UUID?
        let createdAt: Date?
        let updatedAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            projectId: self.$project.id,
            size: self.size,
            sizeGB: self.sizeGB,
            format: self.format,
            volumeType: self.volumeType,
            status: self.status,
            errorMessage: self.errorMessage,
            storagePath: self.storagePath,
            hypervisorId: self.hypervisorId,
            vmId: self.$vm.id,
            deviceName: self.deviceName,
            bootOrder: self.bootOrder,
            sourceImageId: self.$sourceImage.id,
            sourceVolumeId: self.$sourceVolume.id,
            createdById: self.$createdBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }
}

// MARK: - Computed Properties

extension Volume {
    var sizeGB: Double {
        return Double(size) / 1024.0 / 1024.0 / 1024.0
    }

    var sizeMB: Double {
        return Double(size) / 1024.0 / 1024.0
    }

    var isAttached: Bool {
        return status == .attached
    }

    var isAvailable: Bool {
        return status == .available
    }

    var canAttach: Bool {
        return status == .available
    }

    var canDetach: Bool {
        return status == .attached
    }

    var canResize: Bool {
        // Can only resize when not attached (offline resize)
        return status == .available
    }

    var canSnapshot: Bool {
        return status == .available || status == .attached
    }

    var canDelete: Bool {
        return status == .available || status == .error
    }

    /// Builds the storage path for this volume
    func buildStoragePath(basePath: String) -> String? {
        guard let id = self.id else { return nil }
        return "\(basePath)/\(id)/volume.\(format.rawValue)"
    }
}

// MARK: - Request/Response DTOs

struct CreateVolumeRequest: Content {
    let name: String
    let description: String?
    let projectId: UUID?
    let sizeGB: Int           // Size in GB for user convenience
    let format: String?       // "qcow2" or "raw", defaults to qcow2
    let volumeType: String?   // "boot" or "data", defaults to data
    let sourceImageId: UUID?  // Create volume from image
}

struct UpdateVolumeRequest: Content {
    let name: String?
    let description: String?
}

struct AttachVolumeRequest: Content {
    let vmId: UUID
    let deviceName: String?   // e.g., "disk1", auto-generated if not provided
    let bootOrder: Int?       // Boot priority (lower = higher priority)
    let readonly: Bool?       // Mount as read-only
}

struct ResizeVolumeRequest: Content {
    let sizeGB: Int           // New size in GB (must be larger than current)
}

struct CloneVolumeRequest: Content {
    let name: String
    let description: String?
}

struct VolumeResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let projectId: UUID?
    let size: Int64
    let sizeFormatted: String
    let format: VolumeFormat
    let volumeType: VolumeType
    let status: VolumeStatus
    let errorMessage: String?
    let hypervisorId: String?
    let vmId: UUID?
    let deviceName: String?
    let bootOrder: Int?
    let sourceImageId: UUID?
    let sourceVolumeId: UUID?
    let createdById: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from volume: Volume) {
        self.id = volume.id
        self.name = volume.name
        self.description = volume.description
        self.projectId = volume.$project.id
        self.size = volume.size
        self.sizeFormatted = VolumeResponse.formatSize(volume.size)
        self.format = volume.format
        self.volumeType = volume.volumeType
        self.status = volume.status
        self.errorMessage = volume.errorMessage
        self.hypervisorId = volume.hypervisorId
        self.vmId = volume.$vm.id
        self.deviceName = volume.deviceName
        self.bootOrder = volume.bootOrder
        self.sourceImageId = volume.$sourceImage.id
        self.sourceVolumeId = volume.$sourceVolume.id
        self.createdById = volume.$createdBy.id
        self.createdAt = volume.createdAt
        self.updatedAt = volume.updatedAt
    }

    static func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.2f KB", kb)
    }
}

// MARK: - Errors

enum VolumeError: Error, LocalizedError, Sendable {
    case volumeNotFound(UUID)
    case volumeNotAvailable(UUID, VolumeStatus)
    case volumeAlreadyAttached(UUID)
    case volumeNotAttached(UUID)
    case invalidFormat(String)
    case invalidVolumeType(String)
    case resizeTooSmall(Int64, Int64)  // current, requested
    case attachFailed(String)
    case detachFailed(String)
    case createFailed(String)
    case deleteFailed(String)
    case snapshotFailed(String)
    case cloneFailed(String)
    case hypervisorMismatch(String)   // Volume and VM on different hypervisors
    case firecrackerNotSupported      // Firecracker doesn't support volumes

    var errorDescription: String? {
        switch self {
        case .volumeNotFound(let id):
            return "Volume '\(id)' not found."
        case .volumeNotAvailable(let id, let status):
            return "Volume '\(id)' is not available. Current status: \(status.rawValue)"
        case .volumeAlreadyAttached(let id):
            return "Volume '\(id)' is already attached to a VM."
        case .volumeNotAttached(let id):
            return "Volume '\(id)' is not attached to any VM."
        case .invalidFormat(let format):
            return "Invalid volume format: \(format). Must be 'qcow2' or 'raw'."
        case .invalidVolumeType(let volumeType):
            return "Invalid volume type: \(volumeType). Must be 'boot' or 'data'."
        case .resizeTooSmall(let current, let requested):
            return "Cannot resize volume: requested size (\(requested) bytes) must be larger than current size (\(current) bytes)."
        case .attachFailed(let reason):
            return "Failed to attach volume: \(reason)"
        case .detachFailed(let reason):
            return "Failed to detach volume: \(reason)"
        case .createFailed(let reason):
            return "Failed to create volume: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete volume: \(reason)"
        case .snapshotFailed(let reason):
            return "Failed to create snapshot: \(reason)"
        case .cloneFailed(let reason):
            return "Failed to clone volume: \(reason)"
        case .hypervisorMismatch(let reason):
            return "Hypervisor mismatch: \(reason)"
        case .firecrackerNotSupported:
            return "Volume operations are not supported for Firecracker VMs. Firecracker only supports a single root disk."
        }
    }
}
