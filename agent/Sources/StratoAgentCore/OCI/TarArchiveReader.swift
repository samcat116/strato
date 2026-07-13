import Foundation

/// One entry's metadata from a tar stream.
public struct TarEntry: Sendable, Equatable {
    public enum EntryType: Sendable, Equatable {
        case file
        case directory
        case symbolicLink
        case hardLink
        case characterDevice
        case blockDevice
        case fifo
        /// A type flag the unpacker has no use for (sparse files, solaris
        /// extensions); entries of this type are skipped with a warning.
        case unsupported(UInt8)
    }

    public let name: String
    public let type: EntryType
    /// Content length in bytes (0 for everything but regular files in
    /// well-formed archives).
    public let size: Int64
    /// Permission bits (the low 12 bits: rwx + setuid/setgid/sticky).
    public let mode: UInt16
    public let uid: Int
    public let gid: Int
    /// Symlink target or hardlink source; empty for other types.
    public let linkName: String
    public let modificationTime: Date?
}

/// A sequential reader for the tar streams inside OCI layers: POSIX ustar
/// plus the two extension families real-world layers use — PAX `x` records
/// (long paths, large values) and GNU `L`/`K` long name/link entries.
///
/// Pure Swift rather than shelling out to system tar because whiteout
/// processing needs per-entry control, behavior must not vary with the host's
/// tar flavor (BSD vs GNU), and the parser must be unit-testable on macOS.
///
/// Usage: call `nextEntry()` in a loop; after a `.file` entry, either stream
/// its content with `readContent` or just call `nextEntry()` again (which
/// skips unconsumed content).
public final class TarArchiveReader {
    public enum TarError: Error, LocalizedError {
        case unreadable(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "Cannot read tar archive: \(detail)"
            case .malformed(let detail): return "Malformed tar archive: \(detail)"
            }
        }
    }

    private static let blockSize = 1024 * 1024
    /// Sanity cap on PAX/GNU metadata entry sizes — a hostile layer must not
    /// make the reader buffer gigabytes of "metadata".
    private static let maxMetadataSize: Int64 = 1024 * 1024

    private let fileHandle: FileHandle
    /// Unconsumed content bytes (plus padding) of the current entry.
    private var pendingSkip: UInt64 = 0
    /// Content bytes of the current entry not yet handed to `readContent`.
    private var contentRemaining: Int64 = 0

    public init(path: String) throws {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            throw TarError.unreadable(path)
        }
        self.fileHandle = fileHandle
    }

    deinit {
        try? fileHandle.close()
    }

    /// Returns the next real entry, transparently consuming PAX/GNU metadata
    /// entries, or nil at end of archive.
    public func nextEntry() throws -> TarEntry? {
        try skipPendingContent()

        // Overrides accumulated from PAX/GNU metadata entries, applied to the
        // next real header.
        var nameOverride: String?
        var linkNameOverride: String?
        var sizeOverride: Int64?
        var uidOverride: Int?
        var gidOverride: Int?

        while true {
            guard let block = try readBlock() else { return nil }
            if block.allSatisfy({ $0 == 0 }) {
                // End-of-archive marker is two zero blocks; tolerate one
                // followed by EOF, and ignore trailing padding.
                return nil
            }

            let header = try parseHeader(block)
            switch header.typeFlag {
            case UInt8(ascii: "x"), UInt8(ascii: "X"):
                let records = try parsePaxRecords(readMetadataContent(size: header.size))
                if let path = records["path"] { nameOverride = path }
                if let linkPath = records["linkpath"] { linkNameOverride = linkPath }
                if let size = records["size"], let value = Int64(size) { sizeOverride = value }
                if let uid = records["uid"], let value = Int(uid) { uidOverride = value }
                if let gid = records["gid"], let value = Int(gid) { gidOverride = value }
            case UInt8(ascii: "g"):
                // Global PAX defaults: not produced by image builders; skip.
                _ = try readMetadataContent(size: header.size)
            case UInt8(ascii: "L"):
                nameOverride = try trimNulString(readMetadataContent(size: header.size))
            case UInt8(ascii: "K"):
                linkNameOverride = try trimNulString(readMetadataContent(size: header.size))
            default:
                var name = nameOverride ?? header.name
                let size = sizeOverride ?? header.size
                var type = entryType(for: header.typeFlag)
                // Pre-POSIX archives mark directories as files with a
                // trailing slash.
                if type == .file, name.hasSuffix("/") {
                    type = .directory
                }
                if type == .directory, name.hasSuffix("/") {
                    name = String(name.dropLast())
                }

                // Content follows only file entries in well-formed archives,
                // but pendingSkip honors any nonzero size so a weird archive
                // cannot desynchronize the stream.
                contentRemaining = type == .file ? size : 0
                pendingSkip = UInt64(Self.paddedSize(size))

                return TarEntry(
                    name: name,
                    type: type,
                    size: size,
                    mode: UInt16(header.mode & 0o7777),
                    uid: uidOverride ?? header.uid,
                    gid: gidOverride ?? header.gid,
                    linkName: linkNameOverride ?? header.linkName,
                    modificationTime: header.modificationTime
                )
            }
        }
    }

    /// Streams the current file entry's content in chunks. Must be called at
    /// most once per entry, before the next `nextEntry()`.
    public func readContent(_ consume: (Data) throws -> Void) throws {
        while contentRemaining > 0 {
            let want = Int(min(contentRemaining, Int64(Self.blockSize)))
            let chunk = fileHandle.readData(ofLength: want)
            guard !chunk.isEmpty else {
                throw TarError.malformed("archive truncated mid-content")
            }
            contentRemaining -= Int64(chunk.count)
            pendingSkip -= UInt64(chunk.count)
            try consume(chunk)
        }
    }

    // MARK: - Header parsing

    private struct RawHeader {
        let name: String
        let mode: UInt32
        let uid: Int
        let gid: Int
        let size: Int64
        let modificationTime: Date?
        let typeFlag: UInt8
        let linkName: String
    }

    private func parseHeader(_ block: Data) throws -> RawHeader {
        try verifyChecksum(block)

        var name = Self.cString(block, 0, 100)
        let linkName = Self.cString(block, 157, 100)
        let magic = Self.cString(block, 257, 6)

        // ustar path prefix: logically prepended to the name field.
        if magic.hasPrefix("ustar") {
            let prefix = Self.cString(block, 345, 155)
            if !prefix.isEmpty {
                name = prefix + "/" + name
            }
        }

        let mtimeSeconds = try Self.number(block, 136, 12)
        return RawHeader(
            name: name,
            mode: UInt32(truncatingIfNeeded: try Self.number(block, 100, 8)),
            uid: Int(try Self.number(block, 108, 8)),
            gid: Int(try Self.number(block, 116, 8)),
            size: try Self.number(block, 124, 12),
            modificationTime: mtimeSeconds > 0
                ? Date(timeIntervalSince1970: TimeInterval(mtimeSeconds)) : nil,
            typeFlag: block[block.startIndex + 156],
            linkName: linkName
        )
    }

    private func verifyChecksum(_ block: Data) throws {
        let stored = try Self.number(block, 148, 8)
        var sum: Int64 = 0
        for (offset, byte) in block.enumerated() {
            // The checksum field itself is summed as if it were spaces.
            sum += (148..<156).contains(offset) ? 32 : Int64(byte)
        }
        guard sum == stored else {
            throw TarError.malformed("header checksum mismatch (stored \(stored), computed \(sum))")
        }
    }

    private func entryType(for typeFlag: UInt8) -> TarEntry.EntryType {
        switch typeFlag {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            return .file
        case UInt8(ascii: "1"):
            return .hardLink
        case UInt8(ascii: "2"):
            return .symbolicLink
        case UInt8(ascii: "3"):
            return .characterDevice
        case UInt8(ascii: "4"):
            return .blockDevice
        case UInt8(ascii: "5"):
            return .directory
        case UInt8(ascii: "6"):
            return .fifo
        default:
            return .unsupported(typeFlag)
        }
    }

    // MARK: - Field decoding

    /// NUL-terminated (possibly unterminated) string field.
    private static func cString(_ block: Data, _ offset: Int, _ length: Int) -> String {
        let start = block.startIndex + offset
        var field = block[start..<start + length]
        if let nul = field.firstIndex(of: 0) {
            field = field[field.startIndex..<nul]
        }
        return String(decoding: field, as: UTF8.self)
    }

    /// Numeric field: octal ASCII, or GNU base-256 when the first byte has
    /// the high bit set (used for sizes ≥ 8 GiB).
    private static func number(_ block: Data, _ offset: Int, _ length: Int) throws -> Int64 {
        let start = block.startIndex + offset
        let field = block[start..<start + length]

        if let first = field.first, first & 0x80 != 0 {
            var value = Int64(first & 0x7f)
            for byte in field.dropFirst() {
                let (shifted, overflowed) = value.multipliedReportingOverflow(by: 256)
                guard !overflowed else { throw TarError.malformed("base-256 numeric field overflow") }
                value = shifted | Int64(byte)
            }
            return value
        }

        let text = String(decoding: field, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if text.isEmpty { return 0 }
        guard let value = Int64(text, radix: 8) else {
            throw TarError.malformed("invalid octal field '\(text)'")
        }
        return value
    }

    /// Parses PAX extended-header records: repeated `"<len> <key>=<value>\n"`
    /// where len counts the whole record including itself.
    private func parsePaxRecords(_ data: Data) throws -> [String: String] {
        var records: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let space = data[index...].firstIndex(of: UInt8(ascii: " ")) else {
                throw TarError.malformed("PAX record without length delimiter")
            }
            guard let length = Int(String(decoding: data[index..<space], as: UTF8.self)), length > 0,
                data.distance(from: index, to: data.endIndex) >= length
            else {
                throw TarError.malformed("PAX record with invalid length")
            }
            let recordEnd = data.index(index, offsetBy: length)
            // Record body: after the space, up to (excluding) the trailing \n.
            let body = data[data.index(after: space)..<data.index(before: recordEnd)]
            let text = String(decoding: body, as: UTF8.self)
            if let equals = text.firstIndex(of: "=") {
                records[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
            index = recordEnd
        }
        return records
    }

    // MARK: - Stream positioning

    private func readBlock() throws -> Data? {
        let block = fileHandle.readData(ofLength: 512)
        if block.isEmpty { return nil }
        guard block.count == 512 else {
            throw TarError.malformed("archive truncated mid-header")
        }
        return block
    }

    private func readMetadataContent(size: Int64) throws -> Data {
        guard size <= Self.maxMetadataSize else {
            throw TarError.malformed("metadata entry of \(size) bytes exceeds sanity limit")
        }
        let padded = Self.paddedSize(size)
        let data = fileHandle.readData(ofLength: Int(padded))
        guard Int64(data.count) == padded else {
            throw TarError.malformed("archive truncated mid-metadata")
        }
        return data.prefix(Int(size))
    }

    private func trimNulString(_ data: Data) -> String {
        var content = data
        if let nul = content.firstIndex(of: 0) {
            content = content[content.startIndex..<nul]
        }
        return String(decoding: content, as: UTF8.self)
    }

    private func skipPendingContent() throws {
        guard pendingSkip > 0 else { return }
        let currentOffset = fileHandle.offsetInFile
        fileHandle.seek(toFileOffset: currentOffset + pendingSkip)
        pendingSkip = 0
        contentRemaining = 0
    }

    private static func paddedSize(_ size: Int64) -> Int64 {
        (size + 511) / 512 * 512
    }
}
