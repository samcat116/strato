import Fluent
import Vapor
import Foundation

/// Represents the format of a VM disk image
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case qcow2 = "qcow2"
    case raw = "raw"
}

/// Represents the status of an image during its lifecycle
public enum ImageStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"           // Initial state, waiting for upload/fetch
    case uploading = "uploading"       // File is being uploaded
    case downloading = "downloading"   // File is being fetched from URL
    case validating = "validating"     // File is being validated (format, checksum)
    case ready = "ready"               // Image is ready for use
    case error = "error"               // An error occurred
}

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

    // File information
    @Field(key: "filename")
    var filename: String

    @Field(key: "size")
    var size: Int64

    @Enum(key: "format")
    var format: ImageFormat

    @OptionalField(key: "checksum")
    var checksum: String?

    // Storage location (relative path from IMAGE_STORAGE_PATH)
    @OptionalField(key: "storage_path")
    var storagePath: String?

    // Status tracking
    @Enum(key: "status")
    var status: ImageStatus

    @OptionalField(key: "source_url")
    var sourceURL: String?

    @OptionalField(key: "download_progress")
    var downloadProgress: Int?

    @OptionalField(key: "error_message")
    var errorMessage: String?

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
        filename: String,
        size: Int64 = 0,
        format: ImageFormat = .qcow2,
        status: ImageStatus = .pending,
        uploadedByID: UUID,
        sourceURL: String? = nil,
        defaultCpu: Int? = nil,
        defaultMemory: Int64? = nil,
        defaultDisk: Int64? = nil,
        defaultCmdline: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$project.id = projectID
        self.filename = filename
        self.size = size
        self.format = format
        self.status = status
        self.$uploadedBy.id = uploadedByID
        self.sourceURL = sourceURL
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.defaultDisk = defaultDisk
        self.defaultCmdline = defaultCmdline
    }
}

extension Image: Content {}

// MARK: - Public DTO

extension Image {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let projectId: UUID?
        let filename: String
        let size: Int64
        let format: ImageFormat
        let checksum: String?
        let status: ImageStatus
        let sourceURL: String?
        let downloadProgress: Int?
        let errorMessage: String?
        let defaultCpu: Int?
        let defaultMemory: Int64?
        let defaultDisk: Int64?
        let defaultCmdline: String?
        let uploadedById: UUID?
        let createdAt: Date?
        let updatedAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            projectId: self.$project.id,
            filename: self.filename,
            size: self.size,
            format: self.format,
            checksum: self.checksum,
            status: self.status,
            sourceURL: self.sourceURL,
            downloadProgress: self.downloadProgress,
            errorMessage: self.errorMessage,
            defaultCpu: self.defaultCpu,
            defaultMemory: self.defaultMemory,
            defaultDisk: self.defaultDisk,
            defaultCmdline: self.defaultCmdline,
            uploadedById: self.$uploadedBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }
}

// MARK: - Computed Properties

extension Image {
    var sizeGB: Double {
        return Double(size) / 1024.0 / 1024.0 / 1024.0
    }

    var sizeMB: Double {
        return Double(size) / 1024.0 / 1024.0
    }

    var isReady: Bool {
        return status == .ready
    }

    var isDownloading: Bool {
        return status == .downloading || status == .uploading
    }

    var hasError: Bool {
        return status == .error
    }

    /// Builds the storage path for this image
    func buildStoragePath() -> String? {
        guard let id = self.id else { return nil }
        let projectId = self.$project.id
        return "\(projectId)/\(id)/\(filename)"
    }

    var defaultMemoryMB: Int? {
        guard let memory = defaultMemory else { return nil }
        return Int(memory / 1024 / 1024)
    }

    var defaultDiskGB: Int? {
        guard let disk = defaultDisk else { return nil }
        return Int(disk / 1024 / 1024 / 1024)
    }
}

// MARK: - Request/Response DTOs

struct CreateImageRequest: Content {
    let name: String
    let description: String?
    let sourceURL: String?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?
}

struct UpdateImageRequest: Content {
    let name: String?
    let description: String?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?
}

struct ImageResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let projectId: UUID?
    let filename: String
    let size: Int64
    let sizeFormatted: String
    let format: ImageFormat
    let checksum: String?
    let status: ImageStatus
    let sourceURL: String?
    let downloadProgress: Int?
    let errorMessage: String?
    let defaultCpu: Int?
    let defaultMemory: Int64?
    let defaultDisk: Int64?
    let defaultCmdline: String?
    let uploadedById: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from image: Image) {
        self.id = image.id
        self.name = image.name
        self.description = image.description
        self.projectId = image.$project.id
        self.filename = image.filename
        self.size = image.size
        self.sizeFormatted = ImageResponse.formatSize(image.size)
        self.format = image.format
        self.checksum = image.checksum
        self.status = image.status
        self.sourceURL = image.sourceURL
        self.downloadProgress = image.downloadProgress
        self.errorMessage = image.errorMessage
        self.defaultCpu = image.defaultCpu
        self.defaultMemory = image.defaultMemory
        self.defaultDisk = image.defaultDisk
        self.defaultCmdline = image.defaultCmdline
        self.uploadedById = image.$uploadedBy.id
        self.createdAt = image.createdAt
        self.updatedAt = image.updatedAt
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
        self.downloadProgress = image.downloadProgress
        self.errorMessage = image.errorMessage
        self.size = image.size
        self.checksum = image.checksum
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
    case fileTooLarge(Int64, Int64) // actual, max

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
