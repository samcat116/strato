import Testing
import Foundation
import NIOCore
@testable import App

@Suite("ImageStorageService Tests", .serialized)
final class ImageStorageServiceTests {

    // MARK: - Test Helpers

    /// Creates a temporary storage directory and returns its path
    static func createTempStorageDirectory() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let storagePath = tempDir.appendingPathComponent("strato-test-storage-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        return storagePath
    }

    /// Removes a temporary storage directory
    static func cleanupTempStorageDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Creates a ByteBuffer with test content
    static func createTestBuffer(content: String = "test file content") -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: content.utf8.count)
        buffer.writeString(content)
        return buffer
    }

    // MARK: - Path Building Tests

    @Test("Build file path")
    func testBuildFilePath() {
        let storagePath = "/var/lib/strato/images"
        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"

        let result = ImageStorageService.buildFilePath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let expected = "\(storagePath)/\(projectId)/\(imageId)/\(filename)"
        #expect(result == expected)
    }

    @Test("Build directory path")
    func testBuildDirectoryPath() {
        let storagePath = "/var/lib/strato/images"
        let projectId = UUID()
        let imageId = UUID()

        let result = ImageStorageService.buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let expected = "\(storagePath)/\(projectId)/\(imageId)"
        #expect(result == expected)
    }

    @Test("Get file path joins storage path and relative path")
    func testGetFilePath() {
        let storagePath = "/var/lib/strato/images"
        let relativePath = "project-id/image-id/test.qcow2"

        let result = ImageStorageService.getFilePath(
            storagePath: storagePath,
            relativePath: relativePath
        )

        #expect(result == "/var/lib/strato/images/project-id/image-id/test.qcow2")
    }

    // MARK: - Directory Structure Tests

    @Test("Create directory structure")
    func testCreateDirectoryStructure() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()

        try ImageStorageService.createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let directoryPath = ImageStorageService.buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory)

        #expect(exists == true)
        #expect(isDirectory.boolValue == true)
    }

    @Test("Create directory structure is idempotent")
    func testCreateDirectoryStructureIdempotent() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()

        // Create twice - should not throw
        try ImageStorageService.createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        try ImageStorageService.createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let directoryPath = ImageStorageService.buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        #expect(FileManager.default.fileExists(atPath: directoryPath) == true)
    }

    @Test("Create directory structure creates intermediate directories")
    func testCreateDirectoryStructureCreatesIntermediates() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()

        // Parent directories don't exist yet
        try ImageStorageService.createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        // Verify both project and image directories were created
        let projectPath = "\(storagePath)/\(projectId)"
        let imagePath = "\(storagePath)/\(projectId)/\(imageId)"

        #expect(FileManager.default.fileExists(atPath: projectPath) == true)
        #expect(FileManager.default.fileExists(atPath: imagePath) == true)
    }

    // MARK: - Save File Tests

    @Test("Save file creates file and returns relative path")
    func testSaveFileSuccess() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let buffer = Self.createTestBuffer(content: "test content")

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let expectedRelativePath = "\(projectId)/\(imageId)/\(filename)"
        #expect(relativePath == expectedRelativePath)

        // Verify file exists
        let fullPath = ImageStorageService.getFilePath(storagePath: storagePath, relativePath: relativePath)
        #expect(FileManager.default.fileExists(atPath: fullPath) == true)
    }

    @Test("Save file content matches input")
    func testSaveFileContent() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let content = "test file content for verification"
        let buffer = Self.createTestBuffer(content: content)

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let fullPath = ImageStorageService.getFilePath(storagePath: storagePath, relativePath: relativePath)
        let savedContent = try String(contentsOfFile: fullPath, encoding: .utf8)

        #expect(savedContent == content)
    }

    @Test("Save file handles empty buffer")
    func testSaveFileEmptyBuffer() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "empty.qcow2"
        let buffer = ByteBufferAllocator().buffer(capacity: 0)

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let fullPath = ImageStorageService.getFilePath(storagePath: storagePath, relativePath: relativePath)
        #expect(FileManager.default.fileExists(atPath: fullPath) == true)

        let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
        let size = attributes[.size] as? Int64
        #expect(size == 0)
    }

    // MARK: - File Size Tests

    @Test("Get file size returns correct size")
    func testGetFileSizeSuccess() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let content = "test content"
        let buffer = Self.createTestBuffer(content: content)

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let size = try ImageStorageService.getFileSize(storagePath: storagePath, relativePath: relativePath)

        #expect(size == Int64(content.utf8.count))
    }

    @Test("Get file size returns zero for empty file")
    func testGetFileSizeZeroBytes() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "empty.qcow2"
        let buffer = ByteBufferAllocator().buffer(capacity: 0)

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let size = try ImageStorageService.getFileSize(storagePath: storagePath, relativePath: relativePath)

        #expect(size == 0)
    }

    @Test("Get file size throws for non-existent file")
    func testGetFileSizeFileNotFound() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let relativePath = "non-existent/path/file.qcow2"

        #expect(throws: Error.self) {
            _ = try ImageStorageService.getFileSize(storagePath: storagePath, relativePath: relativePath)
        }
    }

    // MARK: - File Exists Tests

    @Test("File exists returns true when file exists")
    func testFileExistsTrue() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let buffer = Self.createTestBuffer()

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let exists = ImageStorageService.fileExists(storagePath: storagePath, relativePath: relativePath)

        #expect(exists == true)
    }

    @Test("File exists returns false when file does not exist")
    func testFileExistsFalse() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let relativePath = "non-existent/path/file.qcow2"

        let exists = ImageStorageService.fileExists(storagePath: storagePath, relativePath: relativePath)

        #expect(exists == false)
    }

    // MARK: - Delete File Tests

    @Test("Delete file removes file and directory")
    func testDeleteFileSuccess() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let buffer = Self.createTestBuffer()

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        // Verify file exists before deletion
        #expect(ImageStorageService.fileExists(storagePath: storagePath, relativePath: relativePath) == true)

        // Delete
        try ImageStorageService.deleteFile(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        // Verify file no longer exists
        #expect(ImageStorageService.fileExists(storagePath: storagePath, relativePath: relativePath) == false)

        // Verify directory no longer exists
        let directoryPath = ImageStorageService.buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )
        #expect(FileManager.default.fileExists(atPath: directoryPath) == false)
    }

    @Test("Delete file does not throw when file does not exist")
    func testDeleteFileNotExists() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()

        // Should not throw
        try ImageStorageService.deleteFile(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )
    }

    @Test("Delete file removes directory with multiple files")
    func testDeleteFileRemovesAllContents() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()

        // Create directory
        try ImageStorageService.createDirectoryStructure(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        // Create multiple files in the directory
        let directoryPath = ImageStorageService.buildDirectoryPath(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        let file1 = "\(directoryPath)/file1.qcow2"
        let file2 = "\(directoryPath)/file2.qcow2"
        try "content1".data(using: .utf8)!.write(to: URL(fileURLWithPath: file1))
        try "content2".data(using: .utf8)!.write(to: URL(fileURLWithPath: file2))

        // Verify files exist
        #expect(FileManager.default.fileExists(atPath: file1) == true)
        #expect(FileManager.default.fileExists(atPath: file2) == true)

        // Delete
        try ImageStorageService.deleteFile(
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId
        )

        // Verify directory and all files are gone
        #expect(FileManager.default.fileExists(atPath: directoryPath) == false)
    }

    // MARK: - Open File for Reading Tests

    @Test("Open file for reading returns valid file handle")
    func testOpenFileForReading() async throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let projectId = UUID()
        let imageId = UUID()
        let filename = "test.qcow2"
        let content = "readable content"
        let buffer = Self.createTestBuffer(content: content)

        let relativePath = try await ImageStorageService.saveFile(
            data: buffer,
            storagePath: storagePath,
            projectId: projectId,
            imageId: imageId,
            filename: filename
        )

        let fileHandle = try ImageStorageService.openFileForReading(
            storagePath: storagePath,
            relativePath: relativePath
        )
        defer { try? fileHandle.close() }

        let data = fileHandle.readDataToEndOfFile()
        let readContent = String(data: data, encoding: .utf8)

        #expect(readContent == content)
    }

    @Test("Open file for reading throws for non-existent file")
    func testOpenFileForReadingFileNotFound() throws {
        let storagePath = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(storagePath) }

        let relativePath = "non-existent/path/file.qcow2"

        #expect(throws: ImageError.self) {
            _ = try ImageStorageService.openFileForReading(
                storagePath: storagePath,
                relativePath: relativePath
            )
        }
    }

    // MARK: - Default Storage Path Tests

    @Test("Default storage path is platform specific")
    func testDefaultStoragePath() {
        let defaultPath = ImageStorageService.defaultStoragePath

        #if os(macOS)
        #expect(defaultPath.contains("Library/Application Support/strato/images"))
        #else
        #expect(defaultPath == "/var/lib/strato/images")
        #endif
    }
}
