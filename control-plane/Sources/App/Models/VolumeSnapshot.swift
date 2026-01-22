import Fluent
import Vapor
import Foundation

/// Represents the status of a volume snapshot
public enum SnapshotStatus: String, Codable, CaseIterable, Sendable {
    case creating = "creating"     // Snapshot is being created
    case available = "available"   // Snapshot is ready for use
    case restoring = "restoring"   // Snapshot is being restored to a volume
    case deleting = "deleting"     // Snapshot is being deleted
    case error = "error"           // An error occurred
}

final class VolumeSnapshot: Model, @unchecked Sendable {
    static let schema = "volume_snapshots"

    @ID(key: .id)
    var id: UUID?

    // Basic metadata
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Parent volume
    @Parent(key: "volume_id")
    var volume: Volume

    // Project ownership (denormalized for easier querying)
    @Parent(key: "project_id")
    var project: Project

    // Snapshot specifications
    @Field(key: "size")
    var size: Int64  // Size at time of snapshot

    // Status tracking
    @Enum(key: "status")
    var status: SnapshotStatus

    @OptionalField(key: "error_message")
    var errorMessage: String?

    // Storage location
    @OptionalField(key: "storage_path")
    var storagePath: String?

    // Owner tracking
    @Parent(key: "created_by_id")
    var createdBy: User

    // Timestamp
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        volumeID: UUID,
        projectID: UUID,
        size: Int64,
        status: SnapshotStatus = .creating,
        createdByID: UUID
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$volume.id = volumeID
        self.$project.id = projectID
        self.size = size
        self.status = status
        self.$createdBy.id = createdByID
    }
}

extension VolumeSnapshot: Content {}

// MARK: - Public DTO

extension VolumeSnapshot {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let volumeId: UUID?
        let projectId: UUID?
        let size: Int64
        let sizeGB: Double
        let status: SnapshotStatus
        let errorMessage: String?
        let storagePath: String?
        let createdById: UUID?
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            volumeId: self.$volume.id,
            projectId: self.$project.id,
            size: self.size,
            sizeGB: Double(size) / 1024.0 / 1024.0 / 1024.0,
            status: self.status,
            errorMessage: self.errorMessage,
            storagePath: self.storagePath,
            createdById: self.$createdBy.id,
            createdAt: self.createdAt
        )
    }
}

// MARK: - Computed Properties

extension VolumeSnapshot {
    var sizeGB: Double {
        return Double(size) / 1024.0 / 1024.0 / 1024.0
    }

    var sizeMB: Double {
        return Double(size) / 1024.0 / 1024.0
    }

    var isAvailable: Bool {
        return status == .available
    }

    var canRestore: Bool {
        return status == .available
    }

    var canDelete: Bool {
        return status == .available || status == .error
    }

    /// Builds the storage path for this snapshot
    func buildStoragePath(basePath: String, volumeId: UUID) -> String? {
        guard let id = self.id else { return nil }
        return "\(basePath)/\(volumeId)/snapshots/\(id).qcow2"
    }
}

// MARK: - Request/Response DTOs

struct CreateSnapshotRequest: Content {
    let name: String
    let description: String?
}

struct SnapshotResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let volumeId: UUID?
    let projectId: UUID?
    let size: Int64
    let sizeFormatted: String
    let status: SnapshotStatus
    let errorMessage: String?
    let createdById: UUID?
    let createdAt: Date?

    init(from snapshot: VolumeSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.description = snapshot.description
        self.volumeId = snapshot.$volume.id
        self.projectId = snapshot.$project.id
        self.size = snapshot.size
        self.sizeFormatted = SnapshotResponse.formatSize(snapshot.size)
        self.status = snapshot.status
        self.errorMessage = snapshot.errorMessage
        self.createdById = snapshot.$createdBy.id
        self.createdAt = snapshot.createdAt
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

enum SnapshotError: Error, LocalizedError, Sendable {
    case snapshotNotFound(UUID)
    case snapshotNotAvailable(UUID, SnapshotStatus)
    case createFailed(String)
    case deleteFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotNotFound(let id):
            return "Snapshot '\(id)' not found."
        case .snapshotNotAvailable(let id, let status):
            return "Snapshot '\(id)' is not available. Current status: \(status.rawValue)"
        case .createFailed(let reason):
            return "Failed to create snapshot: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete snapshot: \(reason)"
        case .restoreFailed(let reason):
            return "Failed to restore snapshot: \(reason)"
        }
    }
}
