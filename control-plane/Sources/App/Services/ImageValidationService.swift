import Foundation
import Crypto
import NIOCore

/// Service for validating image files (format detection, checksum computation)
struct ImageValidationService {
    /// QCOW2 magic bytes: 0x514649FB (QFI\xFB)
    static let qcow2Magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]

    /// Detects the format of an image file by checking magic bytes
    static func detectFormat(filePath: String) throws -> ImageFormat {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw ImageError.invalidFormat("File does not exist")
        }

        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageError.invalidFormat("Cannot open file for reading")
        }
        defer { try? fileHandle.close() }

        // Read first 4 bytes for magic number detection
        let headerData = fileHandle.readData(ofLength: 4)
        guard headerData.count >= 4 else {
            // If file is too small to have a proper header, assume raw
            return .raw
        }

        let bytes = [UInt8](headerData)

        // Check for QCOW2 magic bytes
        if bytes[0] == qcow2Magic[0] &&
           bytes[1] == qcow2Magic[1] &&
           bytes[2] == qcow2Magic[2] &&
           bytes[3] == qcow2Magic[3] {
            return .qcow2
        }

        // If no recognized format, treat as raw
        return .raw
    }

    /// Detects format from a ByteBuffer (for in-memory data)
    static func detectFormat(from buffer: ByteBuffer) -> ImageFormat {
        guard buffer.readableBytes >= 4 else {
            return .raw
        }

        var tempBuffer = buffer
        guard let bytes = tempBuffer.readBytes(length: 4) else {
            return .raw
        }

        // Check for QCOW2 magic bytes
        if bytes[0] == qcow2Magic[0] &&
           bytes[1] == qcow2Magic[1] &&
           bytes[2] == qcow2Magic[2] &&
           bytes[3] == qcow2Magic[3] {
            return .qcow2
        }

        return .raw
    }

    /// Computes SHA256 checksum of a file using streaming
    static func computeChecksum(filePath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw ImageError.checksumMismatch
        }

        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageError.storageFailed("Cannot open file for checksum computation")
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunks

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes SHA256 checksum from a ByteBuffer
    static func computeChecksum(from buffer: ByteBuffer) -> String {
        var tempBuffer = buffer
        guard let bytes = tempBuffer.readBytes(length: buffer.readableBytes) else {
            return ""
        }

        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates an image file: detects format and computes checksum
    static func validateImage(filePath: String) throws -> (format: ImageFormat, checksum: String) {
        let format = try detectFormat(filePath: filePath)
        let checksum = try computeChecksum(filePath: filePath)
        return (format, checksum)
    }

    /// Verifies that a file's checksum matches an expected value
    static func verifyChecksum(filePath: String, expectedChecksum: String) throws -> Bool {
        let actualChecksum = try computeChecksum(filePath: filePath)
        return actualChecksum.lowercased() == expectedChecksum.lowercased()
    }

    /// Validates that a filename is safe (no path traversal, etc.)
    static func validateFilename(_ filename: String) throws -> String {
        // Remove any path components
        let sanitized = (filename as NSString).lastPathComponent

        // Check for empty filename
        guard !sanitized.isEmpty else {
            throw ImageError.invalidFormat("Empty filename")
        }

        // Check for hidden files
        guard !sanitized.hasPrefix(".") else {
            throw ImageError.invalidFormat("Hidden files not allowed")
        }

        // Check for valid extension
        let validExtensions = ["qcow2", "img", "raw", "iso"]
        let ext = (sanitized as NSString).pathExtension.lowercased()
        guard validExtensions.contains(ext) || ext.isEmpty else {
            throw ImageError.invalidFormat("Invalid file extension: \(ext)")
        }

        // Ensure filename only contains safe characters
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard sanitized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw ImageError.invalidFormat("Filename contains invalid characters")
        }

        return sanitized
    }

    /// Gets the QCOW2 virtual size (if applicable)
    static func getQCOW2VirtualSize(filePath: String) throws -> Int64? {
        let format = try detectFormat(filePath: filePath)
        guard format == .qcow2 else {
            return nil
        }

        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageError.storageFailed("Cannot open file")
        }
        defer { try? fileHandle.close() }

        // QCOW2 header structure:
        // Offset 24-31: Virtual size (8 bytes, big-endian)
        try fileHandle.seek(toOffset: 24)
        let sizeData = fileHandle.readData(ofLength: 8)
        guard sizeData.count == 8 else {
            return nil
        }

        // Convert big-endian bytes to Int64
        var virtualSize: Int64 = 0
        for byte in sizeData {
            virtualSize = (virtualSize << 8) | Int64(byte)
        }

        return virtualSize
    }
}
