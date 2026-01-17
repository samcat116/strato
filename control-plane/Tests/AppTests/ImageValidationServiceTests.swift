import Testing
import Foundation
import NIOCore
@testable import App

@Suite("ImageValidationService Tests", .serialized)
final class ImageValidationServiceTests {

    // MARK: - Test Data Helpers

    /// Creates a ByteBuffer with QCOW2 magic bytes and optional virtual size
    static func createQCOW2Buffer(virtualSize: Int64 = 10 * 1024 * 1024 * 1024) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 72)

        // Magic: QFI\xFB (0x514649FB)
        buffer.writeBytes([0x51, 0x46, 0x49, 0xFB])

        // Version 3 (big-endian, 4 bytes)
        buffer.writeInteger(UInt32(3), endianness: .big)

        // Backing file offset (0 = no backing, 8 bytes)
        buffer.writeInteger(UInt64(0), endianness: .big)

        // Backing file size (4 bytes)
        buffer.writeInteger(UInt32(0), endianness: .big)

        // Cluster bits (16 = 64KB clusters, 4 bytes)
        buffer.writeInteger(UInt32(16), endianness: .big)

        // Virtual size at offset 24 (8 bytes, big-endian)
        buffer.writeInteger(UInt64(virtualSize), endianness: .big)

        // Remaining header fields (zeros)
        buffer.writeRepeatingByte(0, count: 40)

        return buffer
    }

    /// Creates a ByteBuffer with raw (non-QCOW2) data
    static func createRawBuffer(size: Int = 1024) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        // Write some non-magic bytes
        buffer.writeRepeatingByte(0x00, count: size)
        return buffer
    }

    /// Creates a temporary file with given content and returns path
    static func createTempFile(content: Data) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "test-\(UUID().uuidString).bin"
        let filePath = tempDir.appendingPathComponent(filename).path
        try content.write(to: URL(fileURLWithPath: filePath))
        return filePath
    }

    /// Creates a temporary QCOW2 file and returns path
    static func createTempQCOW2File(virtualSize: Int64 = 10 * 1024 * 1024 * 1024) throws -> String {
        var buffer = createQCOW2Buffer(virtualSize: virtualSize)
        let bytes = buffer.readBytes(length: buffer.readableBytes)!
        return try createTempFile(content: Data(bytes))
    }

    /// Creates a temporary raw file and returns path
    static func createTempRawFile(size: Int = 1024) throws -> String {
        var buffer = createRawBuffer(size: size)
        let bytes = buffer.readBytes(length: buffer.readableBytes)!
        return try createTempFile(content: Data(bytes))
    }

    /// Removes a temporary file
    static func removeTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Format Detection (ByteBuffer) Tests

    @Test("Detect QCOW2 format from ByteBuffer")
    func testDetectFormatQCOW2FromBuffer() {
        let buffer = Self.createQCOW2Buffer()
        let format = ImageValidationService.detectFormat(from: buffer)
        #expect(format == .qcow2)
    }

    @Test("Detect raw format from ByteBuffer")
    func testDetectFormatRawFromBuffer() {
        let buffer = Self.createRawBuffer()
        let format = ImageValidationService.detectFormat(from: buffer)
        #expect(format == .raw)
    }

    @Test("Detect raw format from empty ByteBuffer")
    func testDetectFormatEmptyBuffer() {
        let buffer = ByteBufferAllocator().buffer(capacity: 0)
        let format = ImageValidationService.detectFormat(from: buffer)
        #expect(format == .raw)
    }

    @Test("Detect raw format from small ByteBuffer")
    func testDetectFormatSmallBuffer() {
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeBytes([0x51, 0x46]) // Only first 2 bytes of magic
        let format = ImageValidationService.detectFormat(from: buffer)
        #expect(format == .raw)
    }

    // MARK: - Format Detection (File Path) Tests

    @Test("Detect QCOW2 format from file")
    func testDetectFormatQCOW2FromFile() throws {
        let filePath = try Self.createTempQCOW2File()
        defer { Self.removeTempFile(filePath) }

        let format = try ImageValidationService.detectFormat(filePath: filePath)
        #expect(format == .qcow2)
    }

    @Test("Detect raw format from file")
    func testDetectFormatRawFromFile() throws {
        let filePath = try Self.createTempRawFile()
        defer { Self.removeTempFile(filePath) }

        let format = try ImageValidationService.detectFormat(filePath: filePath)
        #expect(format == .raw)
    }

    @Test("Detect raw format from small file")
    func testDetectFormatSmallFile() throws {
        let filePath = try Self.createTempFile(content: Data([0x51, 0x46])) // Only 2 bytes
        defer { Self.removeTempFile(filePath) }

        let format = try ImageValidationService.detectFormat(filePath: filePath)
        #expect(format == .raw)
    }

    @Test("Format detection throws for non-existent file")
    func testDetectFormatFileNotFound() {
        let nonExistentPath = "/tmp/non-existent-\(UUID().uuidString).qcow2"
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.detectFormat(filePath: nonExistentPath)
        }
    }

    // MARK: - Checksum Computation (ByteBuffer) Tests

    @Test("Compute checksum from ByteBuffer")
    func testComputeChecksumFromBuffer() {
        var buffer = ByteBufferAllocator().buffer(capacity: 5)
        buffer.writeString("hello")

        let checksum = ImageValidationService.computeChecksum(from: buffer)

        // SHA256 of "hello"
        let expectedChecksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(checksum == expectedChecksum)
    }

    @Test("Compute checksum from empty ByteBuffer")
    func testComputeChecksumEmptyBuffer() {
        let buffer = ByteBufferAllocator().buffer(capacity: 0)
        let checksum = ImageValidationService.computeChecksum(from: buffer)

        // SHA256 of empty data
        let expectedChecksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(checksum == expectedChecksum)
    }

    // MARK: - Checksum Computation (File Path) Tests

    @Test("Compute checksum from file")
    func testComputeChecksumFromFile() throws {
        let content = "hello".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        let checksum = try ImageValidationService.computeChecksum(filePath: filePath)

        let expectedChecksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(checksum == expectedChecksum)
    }

    @Test("Compute checksum from empty file")
    func testComputeChecksumEmptyFile() throws {
        let filePath = try Self.createTempFile(content: Data())
        defer { Self.removeTempFile(filePath) }

        let checksum = try ImageValidationService.computeChecksum(filePath: filePath)

        let expectedChecksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(checksum == expectedChecksum)
    }

    @Test("Checksum computation throws for non-existent file")
    func testComputeChecksumFileNotFound() {
        let nonExistentPath = "/tmp/non-existent-\(UUID().uuidString).bin"
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.computeChecksum(filePath: nonExistentPath)
        }
    }

    @Test("Checksum is deterministic")
    func testComputeChecksumDeterministic() throws {
        let content = "test content for checksum".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        let checksum1 = try ImageValidationService.computeChecksum(filePath: filePath)
        let checksum2 = try ImageValidationService.computeChecksum(filePath: filePath)

        #expect(checksum1 == checksum2)
    }

    @Test("Buffer and file checksum match for same content")
    func testChecksumBufferMatchesFile() throws {
        let content = "matching content".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        var buffer = ByteBufferAllocator().buffer(capacity: content.count)
        buffer.writeBytes(content)

        let fileChecksum = try ImageValidationService.computeChecksum(filePath: filePath)
        let bufferChecksum = ImageValidationService.computeChecksum(from: buffer)

        #expect(fileChecksum == bufferChecksum)
    }

    // MARK: - Checksum Verification Tests

    @Test("Verify checksum matches")
    func testVerifyChecksumMatch() throws {
        let content = "hello".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        let expectedChecksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let result = try ImageValidationService.verifyChecksum(filePath: filePath, expectedChecksum: expectedChecksum)

        #expect(result == true)
    }

    @Test("Verify checksum mismatch")
    func testVerifyChecksumMismatch() throws {
        let content = "hello".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        let wrongChecksum = "0000000000000000000000000000000000000000000000000000000000000000"
        let result = try ImageValidationService.verifyChecksum(filePath: filePath, expectedChecksum: wrongChecksum)

        #expect(result == false)
    }

    @Test("Verify checksum is case insensitive")
    func testVerifyChecksumCaseInsensitive() throws {
        let content = "hello".data(using: .utf8)!
        let filePath = try Self.createTempFile(content: content)
        defer { Self.removeTempFile(filePath) }

        let uppercaseChecksum = "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"
        let result = try ImageValidationService.verifyChecksum(filePath: filePath, expectedChecksum: uppercaseChecksum)

        #expect(result == true)
    }

    // MARK: - Filename Validation Tests

    @Test("Validate filename with .qcow2 extension")
    func testValidateFilenameQCOW2() throws {
        let result = try ImageValidationService.validateFilename("myimage.qcow2")
        #expect(result == "myimage.qcow2")
    }

    @Test("Validate filename with .img extension")
    func testValidateFilenameImg() throws {
        let result = try ImageValidationService.validateFilename("myimage.img")
        #expect(result == "myimage.img")
    }

    @Test("Validate filename with .raw extension")
    func testValidateFilenameRaw() throws {
        let result = try ImageValidationService.validateFilename("myimage.raw")
        #expect(result == "myimage.raw")
    }

    @Test("Validate filename with .iso extension")
    func testValidateFilenameIso() throws {
        let result = try ImageValidationService.validateFilename("myimage.iso")
        #expect(result == "myimage.iso")
    }

    @Test("Validate filename with no extension")
    func testValidateFilenameNoExtension() throws {
        let result = try ImageValidationService.validateFilename("myimage")
        #expect(result == "myimage")
    }

    @Test("Validate filename strips directory path")
    func testValidateFilenameStripsPath() throws {
        let result = try ImageValidationService.validateFilename("path/to/myimage.qcow2")
        #expect(result == "myimage.qcow2")
    }

    @Test("Validate filename with underscore and dash")
    func testValidateFilenameWithUnderscoreAndDash() throws {
        let result = try ImageValidationService.validateFilename("my_image-v1.qcow2")
        #expect(result == "my_image-v1.qcow2")
    }

    @Test("Validate filename strips path traversal attempts")
    func testValidateFilenamePathTraversal() throws {
        // The function sanitizes by stripping path components, leaving just the filename
        let result = try ImageValidationService.validateFilename("../../../etc/passwd")
        #expect(result == "passwd")
    }

    @Test("Validate filename rejects hidden files")
    func testValidateFilenameHiddenFile() {
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.validateFilename(".hidden.qcow2")
        }
    }

    @Test("Validate filename rejects empty string")
    func testValidateFilenameEmpty() {
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.validateFilename("")
        }
    }

    @Test("Validate filename rejects invalid extension")
    func testValidateFilenameInvalidExtension() {
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.validateFilename("malware.exe")
        }
    }

    @Test("Validate filename rejects spaces")
    func testValidateFilenameWithSpaces() {
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.validateFilename("my image.qcow2")
        }
    }

    @Test("Validate filename rejects special characters")
    func testValidateFilenameSpecialCharacters() {
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.validateFilename("image@v1!.qcow2")
        }
    }

    // MARK: - QCOW2 Virtual Size Tests

    @Test("Get QCOW2 virtual size")
    func testGetQCOW2VirtualSize() throws {
        let expectedSize: Int64 = 10 * 1024 * 1024 * 1024 // 10GB
        let filePath = try Self.createTempQCOW2File(virtualSize: expectedSize)
        defer { Self.removeTempFile(filePath) }

        let virtualSize = try ImageValidationService.getQCOW2VirtualSize(filePath: filePath)

        #expect(virtualSize == expectedSize)
    }

    @Test("Get QCOW2 virtual size returns nil for raw file")
    func testGetQCOW2VirtualSizeRawFile() throws {
        let filePath = try Self.createTempRawFile()
        defer { Self.removeTempFile(filePath) }

        let virtualSize = try ImageValidationService.getQCOW2VirtualSize(filePath: filePath)

        #expect(virtualSize == nil)
    }

    @Test("Get QCOW2 virtual size handles different sizes")
    func testGetQCOW2VirtualSizeDifferentSizes() throws {
        let sizes: [Int64] = [
            1 * 1024 * 1024 * 1024,      // 1GB
            50 * 1024 * 1024 * 1024,     // 50GB
            100 * 1024 * 1024 * 1024,    // 100GB
        ]

        for expectedSize in sizes {
            let filePath = try Self.createTempQCOW2File(virtualSize: expectedSize)
            defer { Self.removeTempFile(filePath) }

            let virtualSize = try ImageValidationService.getQCOW2VirtualSize(filePath: filePath)
            #expect(virtualSize == expectedSize, "Expected \(expectedSize), got \(String(describing: virtualSize))")
        }
    }

    @Test("Get QCOW2 virtual size throws for non-existent file")
    func testGetQCOW2VirtualSizeFileNotFound() {
        let nonExistentPath = "/tmp/non-existent-\(UUID().uuidString).qcow2"
        #expect(throws: ImageError.self) {
            _ = try ImageValidationService.getQCOW2VirtualSize(filePath: nonExistentPath)
        }
    }

    // MARK: - Validate Image Tests

    @Test("Validate image returns format and checksum")
    func testValidateImage() throws {
        let filePath = try Self.createTempQCOW2File()
        defer { Self.removeTempFile(filePath) }

        let (format, checksum) = try ImageValidationService.validateImage(filePath: filePath)

        #expect(format == .qcow2)
        #expect(checksum.count == 64) // SHA256 hex string length
    }

    @Test("Validate raw image")
    func testValidateRawImage() throws {
        let filePath = try Self.createTempRawFile()
        defer { Self.removeTempFile(filePath) }

        let (format, checksum) = try ImageValidationService.validateImage(filePath: filePath)

        #expect(format == .raw)
        #expect(checksum.count == 64)
    }
}
