#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

/// A stage is reclaimable only with its original VM/inode identity, an exclusive
/// lease, and durable proof that no generator was started (or that it returned).
/// A process can outlive the agent, so an abandoned `.building` is deliberately
/// refused even after its directory lock is released. Age is never proof.
final class CloudInitStaging {
    private struct Identity: Codable, Equatable {
        let version: Int
        let vmID: String
        let owner: UInt32
        let parentDevice: UInt64
        let parentInode: UInt64
        let stageDevice: UInt64
        let stageInode: UInt64
    }

    let path: String
    private let descriptor: CInt
    private let parent: CInt
    private let identity: Identity
    private static let name = ".cloud-init-staging"
    private static let marker = ".strato-owner.json"
    private static let building = ".building"

    init(vmDirectory: String, vmID: String, effectiveUID: uid_t = geteuid()) throws {
        path = vmDirectory + "/" + Self.name
        parent = open(vmDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Self.failure("open staging parent", vmDirectory) }
        var fresh = false
        if mkdirat(parent, Self.name, 0o700) == 0 {
            fresh = true
        } else if errno != EEXIST {
            let error = Self.failure("create staging", path)
            _ = close(parent)
            throw error
        }
        descriptor = openat(parent, Self.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = Self.failure("open staging", path)
            _ = close(parent)
            throw error
        }
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw Self.failure("refuse busy staging", path)
            }
            var stage = stat()
            var container = stat()
            guard fstat(descriptor, &stage) == 0, fstat(parent, &container) == 0,
                stage.st_uid == effectiveUID, container.st_uid == effectiveUID,
                stage.st_mode & 0o077 == 0
            else { throw Self.failure("refuse foreign or public staging", path, EPERM) }
            identity = Identity(
                version: 1, vmID: vmID, owner: UInt32(effectiveUID),
                parentDevice: UInt64(container.st_dev), parentInode: UInt64(container.st_ino),
                stageDevice: UInt64(stage.st_dev), stageInode: UInt64(stage.st_ino))
            if fresh {
                // Publish provenance before any tenant documents exist. An
                // interrupted marker publication remains unknown and refused.
                try createFile(Self.marker, data: JSONEncoder().encode(identity))
                guard Self.synchronize(parent) == 0 else { throw Self.failure("sync staging parent", path) }
            } else {
                try verifyIdentity()
                try removeContents()
            }
        } catch {
            _ = close(descriptor)
            _ = close(parent)
            throw error
        }
    }

    deinit {
        _ = close(descriptor)
        _ = close(parent)
    }

    func generatorWillStart() throws {
        try verifyIdentity()
        // Persist before spawn; a crash cannot expose an apparently idle stage
        // to another agent while an orphaned generator is still using it.
        try createFile(Self.building, data: Data())
    }

    func generatorDidFinish() throws {
        try verifyIdentity()
        try requireFile(Self.building, in: descriptor)
        guard unlinkat(descriptor, Self.building, 0) == 0, Self.synchronize(descriptor) == 0 else {
            throw Self.failure("clear completed staging build", path)
        }
    }

    func cleanup() throws {
        try verifyIdentity()
        try removeContents()
        try verifyIdentity()
        guard unlinkat(descriptor, Self.marker, 0) == 0,
            Self.synchronize(descriptor) == 0,
            unlinkat(parent, Self.name, AT_REMOVEDIR) == 0,
            Self.synchronize(parent) == 0
        else { throw Self.failure("remove owned staging", path) }
    }

    private func verifyIdentity() throws {
        var current = stat()
        guard fstatat(parent, Self.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            UInt64(current.st_dev) == identity.stageDevice,
            UInt64(current.st_ino) == identity.stageInode,
            current.st_uid == uid_t(identity.owner)
        else { throw Self.failure("refuse replaced staging", path, EPERM) }
        try requireFile(Self.marker, in: descriptor)
        let fd = openat(descriptor, Self.marker, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open staging identity", path) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 4096,
            info.st_uid == uid_t(identity.owner), info.st_nlink == 1,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw Self.failure("refuse invalid staging identity", path, EPERM) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count,
            try JSONDecoder().decode(Identity.self, from: Data(bytes)) == identity
        else { throw Self.failure("refuse unknown staging identity", path, EPERM) }
    }

    private func createFile(_ name: String, data: Data) throws {
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("create staging identity", path) }
        defer { _ = close(fd) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Self.failure("write staging identity", path) }
            offset += count
        }
        guard Self.synchronize(fd) == 0, Self.synchronize(descriptor) == 0 else {
            throw Self.failure("sync staging identity", path)
        }
    }

    private func requireFile(_ name: String, in fd: CInt) throws {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_uid == uid_t(identity.owner), info.st_nlink == 1
        else { throw Self.failure("refuse unsafe staging entry", name, EPERM) }
    }

    private func names(in fd: CInt) throws -> [String] {
        // Enumerate the descriptor, never a potentially replaced path.
        let copy = dup(fd)
        guard copy >= 0 else { throw Self.failure("duplicate staging descriptor", path) }
        guard let directory = fdopendir(copy) else {
            _ = close(copy)
            throw Self.failure("enumerate staging", path)
        }
        defer { _ = closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw Self.failure("enumerate staging", path) }
        return result
    }

    private func removeContents() throws {
        let entries = try names(in: descriptor)
        guard !entries.contains(Self.building),
            Set(entries).isSubset(of: [Self.marker, "documents", "cloud-init.iso"])
        else { throw Self.failure("refuse active or unknown staging", path, EPERM) }
        let documents =
            entries.contains("documents")
            ? openat(descriptor, "documents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
        defer { if documents >= 0 { _ = close(documents) } }
        var documentNames: [String] = []
        if entries.contains("documents") {
            var info = stat()
            guard documents >= 0, fstat(documents, &info) == 0,
                info.st_uid == uid_t(identity.owner), info.st_mode & 0o077 == 0
            else { throw Self.failure("refuse unsafe staging documents", path, EPERM) }
            documentNames = try names(in: documents)
            guard
                documentNames.allSatisfy({ name in
                    ["meta-data", "user-data", "network-config"].contains(name)
                        || ["meta-data", "user-data", "network-config"].contains(where: {
                            OwnedFileCleanup.isStagingName(name, for: $0)
                        })
                })
            else { throw Self.failure("refuse unknown staging document", path, EPERM) }
            for name in documentNames { try requireFile(name, in: documents) }
        }
        if entries.contains("cloud-init.iso") { try requireFile("cloud-init.iso", in: descriptor) }
        // Validate the entire tree before erasing anything, then recheck the
        // bound identity before each descriptor-relative mutation.
        for name in documentNames {
            try verifyIdentity()
            try verifyDocuments(documents)
            try requireFile(name, in: documents)
            guard unlinkat(documents, name, 0) == 0 else { throw Self.failure("remove staging document", path) }
        }
        if documents >= 0 {
            guard Self.synchronize(documents) == 0 else { throw Self.failure("sync staging documents", path) }
            try verifyIdentity()
            try verifyDocuments(documents)
            guard unlinkat(descriptor, "documents", AT_REMOVEDIR) == 0 else {
                throw Self.failure("remove staging documents", path)
            }
        }
        if entries.contains("cloud-init.iso") {
            try verifyIdentity()
            try requireFile("cloud-init.iso", in: descriptor)
            guard unlinkat(descriptor, "cloud-init.iso", 0) == 0 else { throw Self.failure("remove staged ISO", path) }
        }
        guard Self.synchronize(descriptor) == 0 else { throw Self.failure("sync recovered staging", path) }
    }

    private func verifyDocuments(_ documents: CInt) throws {
        var opened = stat()
        var current = stat()
        guard fstat(documents, &opened) == 0,
            fstatat(descriptor, "documents", &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            opened.st_dev == current.st_dev, opened.st_ino == current.st_ino
        else { throw Self.failure("refuse replaced staging documents", path, EPERM) }
    }

    private static func synchronize(_ descriptor: CInt) -> CInt {
        var result: CInt
        repeat {
            #if canImport(Darwin)
            // Match DurableFileWriter's power-loss publication guarantee.
            result = Darwin.fcntl(descriptor, F_FULLFSYNC)
            #else
            result = Glibc.fsync(descriptor)
            #endif
        } while result != 0 && errno == EINTR
        return result
    }

    private static func failure(_ operation: String, _ path: String, _ number: CInt = errno) -> DurableFileWriteError {
        DurableFileWriteError(operation: operation, path: path, errorNumber: number)
    }
}
