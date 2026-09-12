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
        buffer.writeBytes([0x51, 0x46])  // Only first 2 bytes of magic
        let format = ImageValidationService.detectFormat(from: buffer)
        #expect(format == .raw)
    }

    @Test("Read the guest-visible size from a sparse QCOW2 header")
    func testQCOW2VirtualSize() {
        let expectedSize: Int64 = 40 * 1024 * 1024 * 1024
        var buffer = Self.createQCOW2Buffer(virtualSize: expectedSize)
        let header = buffer.readBytes(length: buffer.readableBytes) ?? []

        #expect(
            ImageValidationService.virtualSize(
                format: .qcow2, storedSize: Int64(header.count), headerBytes: header)
                == expectedSize)
    }

    @Test("Raw virtual size is its stored length")
    func testRawVirtualSize() {
        #expect(
            ImageValidationService.virtualSize(
                format: .raw, storedSize: 4096, headerBytes: []) == 4096)
    }

    @Test("A truncated QCOW2 header has no trustworthy virtual size")
    func testTruncatedQCOW2VirtualSize() {
        #expect(
            ImageValidationService.virtualSize(
                format: .qcow2, storedSize: 4, headerBytes: ImageValidationService.qcow2Magic) == nil)
    }

    /// Builds a buffer whose header is `signature` followed by filler, so only
    /// the magic bytes decide the detected format.
    static func createBuffer(signature: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString(signature)
        buffer.writeBytes([UInt8](repeating: 0x00, count: 32))
        return buffer
    }

    @Test("Detect VMDK format from ByteBuffer")
    func testDetectFormatVMDKFromBuffer() {
        let format = ImageValidationService.detectFormat(from: Self.createBuffer(signature: "KDMV"))
        #expect(format == .vmdk)
    }

    @Test("Detect VHDX format from ByteBuffer")
    func testDetectFormatVHDXFromBuffer() {
        let format = ImageValidationService.detectFormat(
            from: Self.createBuffer(signature: "vhdxfile"))
        #expect(format == .vhdx)
    }

    @Test("Detect VHD format from a header-copy footer signature")
    func testDetectFormatVHDFromBuffer() {
        let format = ImageValidationService.detectFormat(
            from: Self.createBuffer(signature: "conectix"))
        #expect(format == .vhd)
    }

    /// `vhdxfile` starts with `vhdx`, so signature order matters: a naive
    /// shortest-first match could report the wrong format here.
    @Test("Longer signatures are not shadowed by shorter prefixes")
    func testDetectFormatPrefersLongestSignature() {
        let format = ImageValidationService.detectFormat(
            from: Self.createBuffer(signature: "vhdxfile"))
        #expect(format != .vhd)
        #expect(format == .vhdx)
    }

    /// qcow2/vhdx always carry a header signature, so its absence disproves a
    /// claim of them. A headerless file could genuinely be raw, a fixed VHD, or
    /// a flat VMDK, so those claims can't be contradicted.
    @Test(
        "Formats whose signature is mandatory are identified as such",
        arguments: [
            (ImageFormat.qcow2, true),
            (ImageFormat.vhdx, true),
            (ImageFormat.raw, false),
            (ImageFormat.vhd, false),
            (ImageFormat.vmdk, false),
        ])
    func testMustHaveHeaderSignature(format: ImageFormat, expected: Bool) {
        #expect(ImageValidationService.mustHaveHeaderSignature(format) == expected)
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
        let filePath = try Self.createTempFile(content: Data([0x51, 0x46]))  // Only 2 bytes
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

    /// These were rejected before explicit disk formats existed, which would
    /// have blocked a vmdk/vhd/vhdx upload before format detection ever ran.
    @Test("Validate filename with hypervisor-native extensions", arguments: ["vmdk", "vhd", "vhdx"])
    func testValidateFilenameHypervisorFormats(ext: String) throws {
        let result = try ImageValidationService.validateFilename("myimage.\(ext)")
        #expect(result == "myimage.\(ext)")
    }

    /// A disk-image/rootfs artifact is still a disk image, so the artifact path
    /// must not reject a format the upload path accepts.
    @Test(
        "Validate artifact filename with hypervisor-native extensions",
        arguments: ["vmdk", "vhd", "vhdx"])
    func testValidateArtifactFilenameHypervisorFormats(ext: String) throws {
        let result = try ImageValidationService.validateArtifactFilename("rootfs.\(ext)")
        #expect(result == "rootfs.\(ext)")
    }

    /// Pins the relationship rather than the contents: the two whitelists drifted
    /// once already when `ImageFormat` grew vmdk/vhd/vhdx and only the disk-image
    /// list was widened.
    @Test("Every disk-image extension is accepted on the artifact path")
    func testArtifactExtensionsSupersetOfDiskImage() throws {
        #expect(
            ImageValidationService.diskImageExtensions.isSubset(
                of: ImageValidationService.artifactExtensions))

        for ext in ImageValidationService.diskImageExtensions {
            let result = try ImageValidationService.validateArtifactFilename("disk.\(ext)")
            #expect(result == "disk.\(ext)")
        }
    }

    /// The disk whitelist is derived from `ImageFormat`, so a new case can't be
    /// added without the filename check learning about it.
    @Test("Every ImageFormat raw value is an accepted disk extension")
    func testDiskImageExtensionsCoverEveryFormat() throws {
        for format in ImageFormat.allCases {
            #expect(ImageValidationService.diskImageExtensions.contains(format.rawValue))
            let result = try ImageValidationService.validateFilename("disk.\(format.rawValue)")
            #expect(result == "disk.\(format.rawValue)")
        }
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

}
