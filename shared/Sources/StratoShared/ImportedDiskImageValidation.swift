import Foundation

/// Checks untrusted import metadata without opening any referenced files.
/// Owned volume/snapshot chains do not pass through this import-only gate.
public enum ImportedDiskImageValidation {
    /// QEMU supports clusters up to 2 MiB. Header extensions live in the first
    /// cluster, so this bounds both streaming retention and parser work.
    public static let probeLength = 2 * 1024 * 1024
    private static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]

    public struct InvalidImage: LocalizedError, Sendable {
        public let reason: String
        public var errorDescription: String? { "Invalid imported qcow2 image: \(reason)" }
    }

    public struct PreparedImage: Sendable {
        public let path: String
        private let directory: URL
        fileprivate init(path: String, directory: URL) { self.path = path; self.directory = directory }
        /// Best-effort cleanup of import-only scratch bytes, including on failure.
        public func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Cache publication can replace a filename between validation and use.
    /// Copy to private scratch first, then validate the exact immutable bytes
    /// that every probe, copy, and conversion will consume. Keeping the basename
    /// and file mode preserves self-contained formats and copy semantics.
    public static func prepare(filePath: String) throws -> PreparedImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strato-image-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent((filePath as NSString).lastPathComponent)
        do {
            try FileManager.default.copyItem(atPath: filePath, toPath: destination.path)
            // A copied symlink would still reopen mutable bytes outside scratch.
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw InvalidImage(reason: "import source must be a regular file")
            }
            try validate(filePath: destination.path)
            return PreparedImage(path: destination.path, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func validate(filePath: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }
        try validate(prefix: Array(try handle.read(upToCount: probeLength) ?? Data()))
    }

    public static func validate(prefix: [UInt8]) throws {
        guard prefix.starts(with: magic) else { return }
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw InvalidImage(reason: reason) }
        }
        func integer(_ offset: Int, _ count: Int) -> UInt64 {
            prefix[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        try require(prefix.count >= 72, "truncated header")
        let version = integer(4, 4)
        try require(version == 2 || version == 3, "unsupported version")
        // backing_file_size is undefined when backing_file_offset is zero.
        try require(integer(8, 8) == 0, "backing file references are not allowed")
        let clusterBits = integer(20, 4)
        try require((9...21).contains(clusterBits), "unsupported cluster size")
        let clusterSize = 1 << Int(clusterBits)
        var headerLength = 72
        if version == 3 {
            try require(prefix.count >= 104, "truncated version 3 header")
            let incompatible = integer(72, 8)
            try require(incompatible & (1 << 2) == 0, "external data files are not allowed")
            try require(incompatible & ~UInt64(0x1f) == 0, "unsupported incompatible features")
            try require(integer(88, 8) & (1 << 1) == 0, "external raw data files are not allowed")
            headerLength = Int(integer(100, 4))
            try require(headerLength >= 104 && headerLength % 8 == 0, "invalid header length")
        }
        try require(headerLength <= clusterSize, "header exceeds first cluster")
        try require(prefix.count >= clusterSize, "truncated first cluster")
        var offset = headerLength
        while offset < clusterSize {
            try require(clusterSize - offset >= 8, "truncated header extension")
            let type = integer(offset, 4)
            let length = integer(offset + 4, 4)
            if type == 0 { return }
            try require(type != 0x44415441, "external data file metadata is not allowed")
            let paddedLength = (length + 7) & ~UInt64(7)
            try require(paddedLength <= UInt64(clusterSize - offset - 8), "header extension exceeds first cluster")
            offset += 8 + Int(paddedLength)
        }
    }
}
