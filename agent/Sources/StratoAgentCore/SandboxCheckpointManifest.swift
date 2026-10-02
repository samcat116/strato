import Crypto
import Foundation
import StratoShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Integrity and local durability evidence, NOT proof that Firecracker can load
/// the checkpoint. STR-312 must obtain that separate proof before destruction.
/// The runtime owns the archive and excludes writers while publishing/verifying.
public struct SandboxCheckpointManifest: Codable, Sendable, Equatable {
    public static let filename = "checkpoint-integrity.json"
    public let version: Int
    public let sandboxId: String
    public let snapshotId: String
    public let identityNonce: String
    public let firecrackerVersion: String
    public let guestControlProtocolVersion: Int
    public let artifacts: [Artifact]

    /// Structural checks only. Call verifyIfPresent to hash the actual files;
    /// this value alone is never a restorable or reclamation proof.
    public var hasValidShape: Bool {
        version == 1 && UUID(uuidString: sandboxId) != nil && UUID(uuidString: snapshotId) != nil
            && !identityNonce.isEmpty && !firecrackerVersion.isEmpty && guestControlProtocolVersion > 0
            && artifacts.count == SandboxSnapshotArtifactKind.allCases.count
            && Set(artifacts.map(\.kind)) == Set(SandboxSnapshotArtifactKind.allCases)
            && artifacts.allSatisfy {
                $0.sizeBytes > 0 && $0.sha256.utf8.count == 64
                    && $0.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
    }

    public struct Artifact: Codable, Sendable, Equatable {
        public let kind: SandboxSnapshotArtifactKind
        public let sizeBytes: Int64
        public let sha256: String
    }

    public enum CheckpointError: Error, Sendable, Equatable {
        case invalidManifest
        case invalidArtifact
        case identityMismatch
        case integrityMismatch
        case ioFailure(Int32)
    }

    /// Flush each pinned regular artifact, hash its bytes, then publish and
    /// flush the manifest and archive directory. A failure never authorizes
    /// teardown. No paths or names from JSON are used to access the filesystem.
    public static func publish(
        directory: String, sandboxId: String, snapshotId: String,
        identityNonce: String, firecrackerVersion: String,
        guestControlProtocolVersion: Int
    ) throws -> Self {
        guard UUID(uuidString: sandboxId) != nil, UUID(uuidString: snapshotId) != nil,
            !identityNonce.isEmpty, !firecrackerVersion.isEmpty,
            guestControlProtocolVersion > 0
        else { throw CheckpointError.invalidManifest }
        let archive = try openDirectory(directory)
        defer { _ = close(archive) }
        let artifacts = try SandboxSnapshotArtifactKind.allCases.map {
            try inspect(kind: $0, archive: archive, flush: true)
        }
        let manifest = Self(
            version: 1, sandboxId: sandboxId, snapshotId: snapshotId,
            identityNonce: identityNonce, firecrackerVersion: firecrackerVersion,
            guestControlProtocolVersion: guestControlProtocolVersion, artifacts: artifacts)
        let data = try JSONEncoder().encode(manifest)
        let temporary = ".checkpoint-integrity-\(UUID().uuidString)"
        let fd = openat(archive, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CheckpointError.ioFailure(errno) }
        defer {
            _ = close(fd)
            _ = unlinkat(archive, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CheckpointError.ioFailure(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CheckpointError.ioFailure(errno) }
        guard renameat(archive, temporary, archive, filename) == 0 else {
            throw CheckpointError.ioFailure(errno)
        }
        guard fsync(archive) == 0 else { throw CheckpointError.ioFailure(errno) }
        // Capture creates both snapshots/<id> and, on first use, snapshots.
        // Flush the sandbox directory too, so that new parent entry survives.
        var parentPath = directory
        for _ in 0..<2 {
            parentPath = (parentPath as NSString).deletingLastPathComponent
            let parent = try openDirectory(parentPath)
            let result = fsync(parent)
            let failure = errno
            _ = close(parent)
            guard result == 0 else { throw CheckpointError.ioFailure(failure) }
        }
        return manifest
    }

    /// Nil is a legacy archive without local evidence. A present but invalid
    /// sidecar always fails closed; it cannot downgrade to the legacy path.
    public static func verifyIfPresent(
        directory: String, sandboxId: String, snapshotId: String, identityNonce: String
    ) throws -> Self? {
        let archive = try openDirectory(directory)
        defer { _ = close(archive) }
        let fd = openat(archive, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CheckpointError.ioFailure(errno) }
        defer { _ = close(fd) }
        let metadata = try regularFile(fd)
        guard metadata.st_size > 0, metadata.st_size <= 65_536 else {
            throw CheckpointError.invalidManifest
        }
        let manifest = try JSONDecoder().decode(Self.self, from: readAll(fd, limit: 65_536))
        guard manifest.hasValidShape else { throw CheckpointError.invalidManifest }
        guard manifest.sandboxId == sandboxId, manifest.snapshotId == snapshotId,
            manifest.identityNonce == identityNonce
        else { throw CheckpointError.identityMismatch }
        for expected in manifest.artifacts {
            let actual = try inspect(kind: expected.kind, archive: archive, flush: false)
            guard expected == actual else { throw CheckpointError.integrityMismatch }
        }
        return manifest
    }

    private static func openDirectory(_ directory: String) throws -> Int32 {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CheckpointError.ioFailure(errno) }
        return fd
    }

    private static func regularFile(_ fd: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw CheckpointError.ioFailure(errno) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1 else {
            throw CheckpointError.invalidArtifact
        }
        return metadata
    }

    private static func inspect(kind: SandboxSnapshotArtifactKind, archive: Int32, flush: Bool) throws -> Artifact {
        let fd = openat(archive, kind.filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CheckpointError.ioFailure(errno) }
        defer { _ = close(fd) }
        let before = try regularFile(fd)
        guard before.st_size > 0 else { throw CheckpointError.invalidArtifact }
        if flush, fsync(fd) != 0 { throw CheckpointError.ioFailure(errno) }
        var hash = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CheckpointError.ioFailure(errno) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { throw CheckpointError.integrityMismatch }
            hash.update(data: Data(buffer.prefix(count)))
        }
        let after = try regularFile(fd)
        guard total == before.st_size, after.st_size == before.st_size else {
            throw CheckpointError.integrityMismatch
        }
        return Artifact(
            kind: kind, sizeBytes: total,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CheckpointError.ioFailure(errno) }
            if count == 0 { return data }
            guard count <= limit - data.count else { throw CheckpointError.invalidManifest }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
