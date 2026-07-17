import Foundation
import Crypto
import NIOCore

/// Service for validating image files (format detection, checksum computation)
struct ImageValidationService {
    /// QCOW2 magic bytes: 0x514649FB (QFI\xFB)
    static let qcow2Magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]

    /// Header signatures we can recognise, longest first so a longer signature
    /// is never shadowed by a shorter prefix.
    ///
    /// VHD's `conectix` lives in a 512-byte *footer*; dynamic/differencing VHDs
    /// repeat it at offset 0, so a header probe catches those but not fixed VHDs.
    /// A fixed VHD is byte-identical to raw plus a trailing footer, which is why
    /// it falls through to `.raw` and why the upload form lets callers say so
    /// explicitly.
    private static let headerSignatures: [(magic: [UInt8], format: ImageFormat)] = [
        (Array("vhdxfile".utf8), .vhdx),
        (Array("conectix".utf8), .vhd),
        (qcow2Magic, .qcow2),
        (Array("KDMV".utf8), .vmdk),
    ]

    /// Number of leading bytes `detectFormat` needs to recognise every signature.
    static let headerProbeLength = 8

    /// Formats that *always* carry their signature at offset 0, so a header
    /// probe finding nothing positively disproves a claim of that format.
    ///
    /// The others can legitimately look like raw data at the head: a fixed VHD
    /// is raw sectors plus a footer at EOF, and a monolithic-flat VMDK's header
    /// is a plain-text descriptor. Claims of those must be taken on trust —
    /// which is much of the point of letting a caller state the format at all.
    static func mustHaveHeaderSignature(_ format: ImageFormat) -> Bool {
        switch format {
        case .qcow2, .vhdx: return true
        case .raw, .vhd, .vmdk: return false
        }
    }

    /// Detects the format of an image file by checking magic bytes
    static func detectFormat(filePath: String) throws -> ImageFormat {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw ImageError.invalidFormat("File does not exist")
        }

        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageError.invalidFormat("Cannot open file for reading")
        }
        defer { try? fileHandle.close() }

        let headerData = fileHandle.readData(ofLength: headerProbeLength)
        return detectFormat(fromHeader: [UInt8](headerData))
    }

    /// Detects format from a ByteBuffer (for in-memory data)
    static func detectFormat(from buffer: ByteBuffer) -> ImageFormat {
        var tempBuffer = buffer
        let available = min(tempBuffer.readableBytes, headerProbeLength)
        let bytes = tempBuffer.readBytes(length: available) ?? []
        return detectFormat(fromHeader: bytes)
    }

    /// Matches a file header against the known signatures.
    ///
    /// Anything unrecognised is reported as `.raw`: raw images have no magic to
    /// match on, so "no signature" and "raw" are indistinguishable here. Callers
    /// that know better can override the result with an explicit format.
    static func detectFormat(fromHeader bytes: [UInt8]) -> ImageFormat {
        for (magic, format) in headerSignatures where bytes.starts(with: magic) {
            return format
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
        let bufferSize = 1024 * 1024  // 1MB chunks

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

    /// Extensions a disk image may carry: every `ImageFormat` plus the
    /// format-agnostic container names (`.img`, `.iso`) whose contents are only
    /// settled by reading the header.
    ///
    /// `validateArtifactFilename` builds on this rather than repeating it — a
    /// disk-image artifact is still a disk image, so a format accepted on the
    /// upload path must not be rejected on the artifact path.
    static let diskImageExtensions: Set<String> =
        Set(ImageFormat.allCases.map(\.rawValue)).union(["img", "iso"])

    /// Extensions only meaningful for the opaque artifact kinds: kernels are
    /// commonly extensionless (`vmlinux`) or `.bin`/`.elf`, root filesystems can
    /// be `.ext4`/`.squashfs`, and initramfs images are often `.cpio.gz`.
    private static let nonDiskArtifactExtensions: Set<String> = [
        "bin", "elf",  // kernels
        "ext2", "ext3", "ext4", "squashfs",  // root filesystems
        "cpio", "gz", "xz", "lz4", "zst",  // initramfs archives / compression
    ]

    /// Everything `validateArtifactFilename` accepts.
    static let artifactExtensions: Set<String> =
        diskImageExtensions.union(nonDiskArtifactExtensions)

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
        let ext = (sanitized as NSString).pathExtension.lowercased()
        guard diskImageExtensions.contains(ext) || ext.isEmpty else {
            throw ImageError.invalidFormat("Invalid file extension: \(ext)")
        }

        // Ensure filename only contains safe characters
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard sanitized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw ImageError.invalidFormat("Filename contains invalid characters")
        }

        return sanitized
    }

    /// Validates a filename for a typed artifact (kernel/rootfs/initramfs/disk-image).
    ///
    /// Accepts everything `validateFilename` does — a disk-image or rootfs
    /// artifact is a disk image, so any format the upload path takes must be
    /// accepted here too — plus the opaque-blob extensions Firecracker artifacts
    /// use. Extensionless names (e.g. `vmlinux`) are allowed. Keeps the same
    /// path-traversal and safe-character guarantees as `validateFilename`.
    static func validateArtifactFilename(_ filename: String) throws -> String {
        // Remove any path components
        let sanitized = (filename as NSString).lastPathComponent

        guard !sanitized.isEmpty else {
            throw ImageError.invalidFormat("Empty filename")
        }

        guard !sanitized.hasPrefix(".") else {
            throw ImageError.invalidFormat("Hidden files not allowed")
        }

        let ext = (sanitized as NSString).pathExtension.lowercased()
        guard artifactExtensions.contains(ext) || ext.isEmpty else {
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
