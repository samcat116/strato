import Foundation
import Vapor
import NIOCore
import NIOPosix

/// Service for managing image file storage
struct ImageStorageService {
    /// Default storage path for images (platform-specific)
    static var defaultStoragePath: String {
        #if os(macOS)
        // On macOS, use user's data directory (writable without root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/images"
        #else
        // On Linux, use system data directory
        return "/var/lib/strato/images"
        #endif
    }

    /// Returns the configured storage path from environment or default
    static func storagePath(from app: Application) -> String {
        return Environment.get("IMAGE_STORAGE_PATH") ?? defaultStoragePath
    }

    /// Builds the full file path for an image
    /// Structure: {storagePath}/{projectId}/{imageId}/{filename}
    static func buildFilePath(
        storagePath: String,
        projectId: UUID,
        imageId: UUID,
        filename: String
    ) -> String {
        return "\(storagePath)/\(projectId)/\(imageId)/\(filename)"
    }

    /// Builds the directory path for an image
    static func buildDirectoryPath(
        storagePath: String,
        projectId: UUID,
        imageId: UUID
    ) -> String {
        return "\(storagePath)/\(projectId)/\(imageId)"
    }

    /// Creates the directory structure for storing an image
    static func createDirectoryStructure(
        storagePath: String,
        projectId: UUID,
        imageId: UUID
    ) throws {
        let directoryPath = buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Saves uploaded file data to storage
    /// Returns the relative storage path
    static func saveFile(
        data: ByteBuffer,
        storagePath: String,
        projectId: UUID,
        imageId: UUID,
        filename: String
    ) async throws -> String {
        // Create directory structure
        try createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let filePath = buildFilePath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        // Convert ByteBuffer to Data and write to file
        var buffer = data
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            throw ImageError.storageFailed("Failed to read file data")
        }

        let fileData = Data(bytes)
        try fileData.write(to: URL(fileURLWithPath: filePath))

        // Return relative path
        return "\(projectId)/\(imageId)/\(filename)"
    }

    /// Saves a file from a file handle (for streaming uploads)
    static func saveFileStreaming(
        from fileHandle: FileHandle,
        to filePath: String,
        storagePath: String,
        projectId: UUID,
        imageId: UUID,
        filename: String,
        onProgress: ((Int64) -> Void)? = nil
    ) async throws -> (relativePath: String, size: Int64) {
        // Create directory structure
        try createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let fullPath = buildFilePath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        // Create output file
        FileManager.default.createFile(atPath: fullPath, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: fullPath) else {
            throw ImageError.storageFailed("Failed to create output file")
        }
        defer { try? outputHandle.close() }

        var totalBytesWritten: Int64 = 0
        let bufferSize = 1024 * 1024 // 1MB chunks

        // Stream data from input to output
        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }

            try outputHandle.write(contentsOf: data)
            totalBytesWritten += Int64(data.count)
            onProgress?(totalBytesWritten)
        }

        let relativePath = "\(projectId)/\(imageId)/\(filename)"
        return (relativePath, totalBytesWritten)
    }

    /// Gets the full file path for an image
    static func getFilePath(
        storagePath: String,
        relativePath: String
    ) -> String {
        return "\(storagePath)/\(relativePath)"
    }

    /// Checks if an image file exists
    static func fileExists(
        storagePath: String,
        relativePath: String
    ) -> Bool {
        let fullPath = getFilePath(storagePath: storagePath, relativePath: relativePath)
        return FileManager.default.fileExists(atPath: fullPath)
    }

    /// Gets the file size
    static func getFileSize(
        storagePath: String,
        relativePath: String
    ) throws -> Int64 {
        let fullPath = getFilePath(storagePath: storagePath, relativePath: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
        guard let size = attributes[.size] as? Int64 else {
            throw ImageError.storageFailed("Could not determine file size")
        }
        return size
    }

    /// Deletes an image file and its directory
    static func deleteFile(
        storagePath: String,
        projectId: UUID,
        imageId: UUID
    ) throws {
        let directoryPath = buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directoryPath) {
            try fileManager.removeItem(atPath: directoryPath)
        }
    }

    /// Opens a file handle for reading (for streaming downloads)
    static func openFileForReading(
        storagePath: String,
        relativePath: String
    ) throws -> FileHandle {
        let fullPath = getFilePath(storagePath: storagePath, relativePath: relativePath)
        guard let fileHandle = FileHandle(forReadingAtPath: fullPath) else {
            throw ImageError.storageFailed("Could not open file for reading")
        }
        return fileHandle
    }

    /// Streams a file as a Response (for download endpoints)
    static func streamFile(
        req: Request,
        storagePath: String,
        relativePath: String,
        filename: String
    ) async throws -> Response {
        let fullPath = getFilePath(storagePath: storagePath, relativePath: relativePath)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound, reason: "Image file not found")
        }

        // Get file size for Content-Length header
        let fileSize = try getFileSize(storagePath: storagePath, relativePath: relativePath)

        // Stream the file
        let response = try await req.fileio.asyncStreamFile(at: fullPath)

        // Set headers for download
        response.headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
        response.headers.add(name: .contentLength, value: String(fileSize))

        return response
    }
}
