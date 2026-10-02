#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Crypto
import Foundation

/// A private, bounded artifact store for preparatory STR-273 work. The caller
/// supplies an existing 0700 directory. No guest or lifecycle code uses it yet.
public actor SandboxLazyMemoryStore {
    public struct Identity: Codable, Sendable, Equatable {
        public let sandboxID: UUID
        public let checkpointID: UUID
        public let generation: UInt64
        public init(sandboxID: UUID, checkpointID: UUID, generation: UInt64) {
            self.sandboxID = sandboxID
            self.checkpointID = checkpointID
            self.generation = generation
        }
    }

    public struct BaseRecord: Codable, Sendable, Equatable {
        public let version: Int
        public let memoryDigest: String
        public let compatibilityDigest: String
        public let trustClass: String
        public let pageSize: Int
        public let byteCount: Int
    }

    private struct DeltaRecord: Codable {
        let version: Int
        let identity: Identity
        let baseKey: String
        let pages: [Int: String]
    }

    public enum StoreError: Error, Equatable {
        case invalidRoot, invalidRecord, integrityMismatch, missing, limitExceeded, pinned, io(Int32)
    }

    private var root: Int32
    private let maximumBytes: Int
    private var pins: [UUID: String] = [:]

    public init(directory: String, maximumBytes: Int = 64 << 20) throws {
        guard maximumBytes > 0, maximumBytes <= 1 << 30 else { throw StoreError.limitExceeded }
        let fd = try Self.openRoot(directory)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            _ = close(fd)
            throw StoreError.invalidRoot
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw StoreError.io(errno)
        }
        self.root = fd
        self.maximumBytes = maximumBytes
    }

    deinit { _ = close(root) }

    /// Atomically publish a memory image and compatibility manifest. Existing
    /// keys are reverified, never overwritten. Total store bytes are bounded.
    public func publishBase(data: Data, compatibilityDigest: String, trustClass: String, pageSize: Int = 4096) throws
        -> String
    {
        guard Self.digestValid(compatibilityDigest), !trustClass.isEmpty, trustClass.utf8.count <= 256,
            pageSize == 4096, !data.isEmpty, data.count <= maximumBytes, data.count % pageSize == 0
        else { throw StoreError.invalidRecord }
        let owned = data.withUnsafeBytes { Data($0) }
        let record = BaseRecord(
            version: 1, memoryDigest: Self.digest(owned), compatibilityDigest: compatibilityDigest,
            trustClass: trustClass, pageSize: pageSize, byteCount: data.count)
        let metadata = try Self.encode(record)
        let key = Self.digest(metadata)
        if try exists(key) {
            _ = try loadBase(key: key, compatibilityDigest: compatibilityDigest, trustClass: trustClass)
            return key
        }
        try reserve(bytes: data.count + metadata.count)
        try publish(directory: key, files: ["memory": owned, "manifest": metadata])
        return key
    }

    public func loadBase(key: String, compatibilityDigest: String, trustClass: String) throws
        -> SandboxLazyMemoryPages.Base
    {
        let dir = try openArtifact(key)
        defer { _ = close(dir) }
        let metadata = try read(dir: dir, name: "manifest", limit: 65536)
        guard Self.digest(metadata) == key else { throw StoreError.integrityMismatch }
        let record = try JSONDecoder().decode(BaseRecord.self, from: metadata)
        guard record.version == 1, record.compatibilityDigest == compatibilityDigest, record.trustClass == trustClass,
            Self.digestValid(record.memoryDigest), Self.digestValid(record.compatibilityDigest),
            record.pageSize == 4096,
            record.byteCount > 0, record.byteCount <= maximumBytes, record.byteCount % record.pageSize == 0
        else {
            throw StoreError.invalidRecord
        }
        let data = try read(dir: dir, name: "memory", limit: record.byteCount)
        guard data.count == record.byteCount else { throw StoreError.integrityMismatch }
        return try SandboxLazyMemoryPages.Base(
            data: data, digest: record.memoryDigest, trustClass: record.trustClass, pageSize: record.pageSize)
    }

    /// Private deltas are bound to sandbox/checkpoint/generation and base class.
    /// Publication returns a unique token. Restart recovery must supply the exact
    /// identity, never search another sandbox's directories for usable pages.
    public func publishDelta(
        identity: Identity, baseKey: String, compatibilityDigest: String, trustClass: String, pages: [Int: Data]
    ) throws -> String {
        let base = try loadBase(key: baseKey, compatibilityDigest: compatibilityDigest, trustClass: trustClass)
        let baseDir = try openArtifact(baseKey)
        defer { _ = close(baseDir) }
        let record = try JSONDecoder().decode(BaseRecord.self, from: read(dir: baseDir, name: "manifest", limit: 65536))
        guard pages.count <= 4096 else { throw StoreError.limitExceeded }
        var files: [String: Data] = [:]
        var hashes: [Int: String] = [:]
        for (page, data) in pages {
            guard page >= 0, page < record.byteCount / base.pageSize, data.count == base.pageSize else {
                throw StoreError.invalidRecord
            }
            let owned = data.withUnsafeBytes { Data($0) }
            files["page-\(page)"] = owned
            hashes[page] = Self.digest(owned)
        }
        files["manifest"] = try Self.encode(
            DeltaRecord(version: 1, identity: identity, baseKey: baseKey, pages: hashes))
        let token = "delta-" + Self.digest(files["manifest"]!)
        if try exists(token) {
            _ = try recoverDelta(
                token: token, identity: identity, baseKey: baseKey,
                compatibilityDigest: compatibilityDigest, trustClass: trustClass)
            return token
        }
        try reserve(bytes: files.values.reduce(0) { $0 + $1.count })
        try publish(directory: token, files: files)
        return token
    }

    public func recoverDelta(
        token: String, identity: Identity, baseKey: String, compatibilityDigest: String, trustClass: String
    ) throws -> SandboxLazyMemoryPages {
        let base = try loadBase(key: baseKey, compatibilityDigest: compatibilityDigest, trustClass: trustClass)
        let dir = try openArtifact(token)
        defer { _ = close(dir) }
        let metadata = try read(dir: dir, name: "manifest", limit: 1 << 20)
        guard token.hasPrefix("delta-"), Self.digest(metadata) == String(token.dropFirst(6)) else {
            throw StoreError.integrityMismatch
        }
        let record = try JSONDecoder().decode(DeltaRecord.self, from: metadata)
        guard record.version == 1, record.identity == identity, record.baseKey == baseKey, record.pages.count <= 4096
        else {
            throw StoreError.invalidRecord
        }
        var result = try SandboxLazyMemoryPages(
            base: base, trustClass: trustClass, maximumDirtyPages: max(1, record.pages.count))
        for (page, digest) in record.pages {
            guard Self.digestValid(digest) else { throw StoreError.invalidRecord }
            let data = try read(dir: dir, name: "page-\(page)", limit: base.pageSize)
            guard data.count == base.pageSize, Self.digest(data) == digest else { throw StoreError.integrityMismatch }
            try result.write(page: page, data: data)
        }
        return result
    }

    @discardableResult
    public func pin(baseKey: String, compatibilityDigest: String, trustClass: String) throws -> UUID {
        guard pins.count < 4096 else { throw StoreError.limitExceeded }
        _ = try loadBase(key: baseKey, compatibilityDigest: compatibilityDigest, trustClass: trustClass)
        let token = UUID()
        pins[token] = baseKey
        return token
    }

    public func unpin(token: UUID) {
        pins.removeValue(forKey: token)
    }

    public func shutdown() throws {
        guard pins.isEmpty else { throw StoreError.pinned }
        if root >= 0 {
            _ = close(root)
            root = -1
        }
    }

    public func evict(key: String) throws {
        guard !pins.values.contains(key) else { throw StoreError.pinned }
        if Self.digestValid(key) {
            for name in try entries(root) where name.hasPrefix("delta-") {
                let delta = try openArtifact(name)
                defer { _ = close(delta) }
                let metadata = try read(dir: delta, name: "manifest", limit: 1 << 20)
                guard Self.digest(metadata) == String(name.dropFirst(6)) else { throw StoreError.integrityMismatch }
                let record = try JSONDecoder().decode(DeltaRecord.self, from: metadata)
                guard record.baseKey != key else { throw StoreError.pinned }
            }
        }
        let fd = try openArtifact(key)
        defer { _ = close(fd) }
        for name in try entries(fd) {
            guard unlinkat(fd, name, 0) == 0 else { throw StoreError.io(errno) }
        }
        guard unlinkat(root, key, AT_REMOVEDIR) == 0, fsync(root) == 0 else { throw StoreError.io(errno) }
    }

    /// A crash may leave a partial stage. It is never a published artifact.
    /// Exclusive ownership serializes staging cleanup and publication.
    /// Committed artifacts are left alone.
    public func recoverStaging() throws {
        for name in try entries(root)
        where name.hasPrefix("stage-") && UUID(uuidString: String(name.dropFirst(6))) != nil {
            try evict(key: name)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func digestValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private static func validKey(_ key: String) -> Bool {
        digestValid(key) || (key.hasPrefix("delta-") && digestValid(String(key.dropFirst(6))))
            || (key.hasPrefix("stage-") && UUID(uuidString: String(key.dropFirst(6))) != nil)
    }

    private static func openRoot(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw StoreError.invalidRoot }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.io(errno) }
        for part in path.split(separator: "/").map(String.init) {
            guard part != ".", part != ".." else {
                _ = close(fd)
                throw StoreError.invalidRoot
            }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            _ = close(fd)
            guard next >= 0 else { throw StoreError.io(errno) }
            fd = next
        }
        return fd
    }
    private func exists(_ key: String) throws -> Bool {
        let fd = openat(root, key, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 {
            _ = close(fd)
            return true
        }
        if errno == ENOENT { return false }
        throw StoreError.io(errno)
    }
    private func openArtifact(_ key: String) throws -> Int32 {
        guard Self.validKey(key) else { throw StoreError.invalidRecord }
        let fd = openat(root, key, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw StoreError.missing }
            throw StoreError.io(errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            _ = close(fd)
            throw StoreError.invalidRecord
        }
        return fd
    }
    private func read(dir: Int32, name: String, limit: Int) throws -> Data {
        guard !name.contains("/"), name != ".", name != ".." else { throw StoreError.invalidRecord }
        let fd = openat(dir, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw StoreError.io(errno) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
            info.st_size >= 0, info.st_size <= limit
        else { throw StoreError.invalidRecord }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Self.posixRead(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw StoreError.io(errno) }
            if count == 0 { return result }
            guard result.count <= limit - count else { throw StoreError.limitExceeded }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func posixRead(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.read(fd, bytes, count)
        #else
        Darwin.read(fd, bytes, count)
        #endif
    }
    static func duplicateDirectoryDescriptor(_ fd: Int32) throws -> Int32 {
        let result = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard result >= 0 else { throw StoreError.io(errno) }
        return result
    }

    private func entries(_ fd: Int32) throws -> [String] {
        // Duplication shares the directory offset
        // rewind before each enumeration.
        let copy = try Self.duplicateDirectoryDescriptor(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { _ = close(copy) }
            throw StoreError.io(errno)
        }
        defer { _ = closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            guard names.count <= 16384 else { throw StoreError.limitExceeded }
            errno = 0
        }
        guard errno == 0 else { throw StoreError.io(errno) }
        return names
    }
    public struct DiskUsage: Sendable, Equatable {
        public fileprivate(set) var baseBytes = 0
        public fileprivate(set) var deltaBytes = 0
        public fileprivate(set) var stagingBytes = 0
        public var totalBytes: Int { baseBytes + deltaBytes + stagingBytes }
    }

    public func diskUsage() throws -> DiskUsage {
        var usage = DiskUsage()
        for key in try entries(root) {
            guard Self.validKey(key) else { throw StoreError.invalidRecord }
            let fd = try openArtifact(key)
            defer { _ = close(fd) }
            for name in try entries(fd) {
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                    info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0,
                    info.st_size <= maximumBytes
                else { throw StoreError.invalidRecord }
                let size = Int(info.st_size)
                guard usage.totalBytes <= maximumBytes - size else { throw StoreError.limitExceeded }
                if key.hasPrefix("stage-") {
                    usage.stagingBytes += size
                } else if key.hasPrefix("delta-") {
                    usage.deltaBytes += size
                } else {
                    usage.baseBytes += size
                }
            }
        }
        return usage
    }

    private func reserve(bytes: Int) throws {
        guard bytes <= maximumBytes else { throw StoreError.limitExceeded }
        guard try diskUsage().totalBytes <= maximumBytes - bytes else { throw StoreError.limitExceeded }
    }
    private func publish(directory: String, files: [String: Data]) throws {
        let stage = "stage-" + UUID().uuidString.lowercased()
        guard mkdirat(root, stage, 0o700) == 0 else { throw StoreError.io(errno) }
        let fd = try openArtifact(stage)
        var committed = false
        defer {
            if !committed {
                for name in files.keys { _ = unlinkat(fd, name, 0) }
                _ = unlinkat(root, stage, AT_REMOVEDIR)
            }
            _ = close(fd)
        }
        for name in files.keys.sorted() {
            let data = files[name]!
            let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o400))
            guard file >= 0 else { throw StoreError.io(errno) }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw StoreError.io(errno) }
                        offset += count
                    }
                }
                guard fsync(file) == 0 else { throw StoreError.io(errno) }
                _ = close(file)
            } catch {
                _ = close(file)
                throw error
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.io(errno) }
        guard renameat(root, stage, root, directory) == 0 else { throw StoreError.io(errno) }
        committed = true
        // A failed parent flush leaves an unacknowledged complete artifact;
        // recovery must reverify it rather than remove a possibly pinned base.
        guard fsync(root) == 0 else { throw StoreError.io(errno) }
    }
}
