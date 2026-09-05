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

    /// Number of leading bytes retained while streaming an image. This covers
    /// every format signature plus qcow2's virtual-size field at offset 24.
    static let headerProbeLength = 64

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

    /// Returns the guest-visible capacity encoded by a disk image without
    /// materializing the streamed object on the control-plane filesystem.
    ///
    /// Raw and flat formats occupy their virtual length. Sparse qcow2 and VMDK
    /// headers encode it directly; VHD's dynamic footer is repeated at offset
    /// zero, while a headerless VHD is the fixed form with one 512-byte footer.
    /// VHDX keeps this value in a variable metadata region beyond the bounded
    /// stream prefix, so it deliberately remains unknown and cannot be used for
    /// capacity-sensitive volume creation.
    static func virtualSize(
        format: ImageFormat, storedSize: Int64, headerBytes: [UInt8]
    ) -> Int64? {
        guard storedSize >= 0 else { return nil }
        switch format {
        case .raw:
            return storedSize
        case .qcow2:
            guard headerBytes.starts(with: qcow2Magic) else { return nil }
            return int64(from: headerBytes, offset: 24, endianness: .big)
        case .vmdk:
            if headerBytes.starts(with: Array("KDMV".utf8)),
                let sectors = uint64(from: headerBytes, offset: 12, endianness: .little),
                sectors <= UInt64(Int64.max / 512)
            {
                return Int64(sectors) * 512
            }
            return nil
        case .vhd:
            if headerBytes.starts(with: Array("conectix".utf8)) {
                return int64(from: headerBytes, offset: 48, endianness: .big)
            }
            return storedSize >= 512 ? storedSize - 512 : nil
        case .vhdx:
            return nil
        }
    }

    private enum IntegerEndianness {
        case big
        case little
    }

    private static func int64(
        from bytes: [UInt8], offset: Int, endianness: IntegerEndianness
    ) -> Int64? {
        guard let value = uint64(from: bytes, offset: offset, endianness: endianness),
            value <= UInt64(Int64.max)
        else { return nil }
        return Int64(value)
    }

    private static func uint64(
        from bytes: [UInt8], offset: Int, endianness: IntegerEndianness
    ) -> UInt64? {
        guard offset >= 0, bytes.count >= offset + MemoryLayout<UInt64>.size else { return nil }
        let field = bytes[offset..<(offset + MemoryLayout<UInt64>.size)]
        switch endianness {
        case .big:
            return field.reduce(0) { ($0 << 8) | UInt64($1) }
        case .little:
            return field.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
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

}
