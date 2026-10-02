import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Restricts only agent-owned state. Disk images, backing chains, sockets and
/// operator files retain their owners' modes. Supported QEMU hosts run QEMU as
/// the agent account (including libvirt's DAC driver).
public enum ManagedStatePermissions {
    public static func prepareVMDirectory(at path: String) throws {
        let descriptor = try directory(at: path, create: true)
        defer { _ = close(descriptor) }
        try restrict(descriptor, mode: 0o700, path: path)
    }

    static func createFreshDirectory(at path: String) throws {
        guard mkdir(path, 0o700) == 0 else { throw failure("create fresh seed staging", path) }
    }

    public static func migrate(at root: String, qemuVMIds: Set<String> = [], legacyStagingRoot: String? = nil) throws {
        let descriptor = try directory(at: root, create: true)
        defer { _ = close(descriptor) }
        // The storage root can also contain sandbox and operator-managed data;
        // existing ancestors are deliberately not chmod'ed.
        let names = try FileManager.default.contentsOfDirectory(atPath: root)
        try migrateRecords(in: descriptor, root: root, names: names)
        var managedVMIds = qemuVMIds
        for name in names where UUID(uuidString: name) != nil {
            let vm = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard vm >= 0 else {
                if !qemuVMIds.contains(name), errno == ENOTDIR || errno == ELOOP { continue }
                throw failure("open VM directory", root + "/" + name)
            }
            defer { _ = close(vm) }
            var info = stat()
            // Manifest ownership or QEMU artifacts identify migration targets.
            // Sandbox UUID directories retain their separate access contract.
            let hasISO = fstatat(vm, "cloud-init.iso", &info, AT_SYMLINK_NOFOLLOW) == 0
            let hasNVRAM = fstatat(vm, "nvram.fd", &info, AT_SYMLINK_NOFOLLOW) == 0
            guard hasISO || hasNVRAM || qemuVMIds.contains(name) else { continue }
            managedVMIds.insert(name)
            try restrict(vm, mode: 0o700, path: root + "/" + name)
            if hasISO { try restrictFile("cloud-init.iso", in: vm, path: root + "/" + name + "/cloud-init.iso") }
        }
        if let legacyStagingRoot {
            try migrateLegacyStaging(in: legacyStagingRoot, vmIds: managedVMIds)
        }
    }

    // The effective UID parameter lets fixtures exercise foreign ownership
    // without changing actual file owners. Production always uses geteuid().
    static func migrateRecords(in descriptor: CInt, root: String, names: [String], effectiveUID: uid_t = geteuid())
        throws
    {
        for name in names {
            let isStaging =
                name == "vm-manifest.json.tmp" || OwnedFileCleanup.isStagingName(name, for: "vm-manifest.json")
            guard
                isStaging || ["vm-manifest.json", "snapshot-records.json", "instance-metadata.json"].contains(name)
                    || name.hasPrefix("vm-manifest.json.corrupt-")
            else { continue }
            try restrictFile(name, in: descriptor, path: root + "/" + name, ownedBy: isStaging ? effectiveUID : nil)
        }
    }

    private static func migrateLegacyStaging(in root: String, vmIds: Set<String>) throws {
        let parent = try directory(at: root, create: false)
        defer { _ = close(parent) }
        let legacyIds = try FileManager.default.contentsOfDirectory(atPath: root).compactMap { name -> String? in
            guard name.hasPrefix("cloud-init-") else { return nil }
            let suffix = String(name.dropFirst("cloud-init-".count))
            return UUID(uuidString: suffix) == nil ? nil : suffix
        }
        // A crash during first creation can precede manifest publication.
        // Recognize the old reserved namespace, but only migrate our own dirs.
        for vmId in vmIds.union(legacyIds) where UUID(uuidString: vmId) != nil {
            let name = "cloud-init-" + vmId
            let path = root + "/" + name
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT { continue }
            guard descriptor >= 0 else {
                if !vmIds.contains(vmId), errno == ELOOP || errno == ENOTDIR { continue }
                throw failure("open legacy seed staging", path)
            }
            defer { _ = close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw failure("inspect legacy seed staging", path) }
            guard info.st_uid == geteuid() else {
                if !vmIds.contains(vmId) { continue }
                throw DurableFileWriteError(operation: "refuse foreign legacy staging", path: path, errorNumber: EPERM)
            }
            try restrict(descriptor, mode: 0o700, path: path)
            for name in ["meta-data", "user-data", "network-config"] {
                if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }
                    throw failure("inspect legacy seed document", path + "/" + name)
                }
                try restrictFile(name, in: descriptor, path: path + "/" + name)
            }
        }
    }

    static func requireRegularOrMissing(at path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return }
            throw failure("inspect state", path)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            throw DurableFileWriteError(operation: "refuse non-private regular file", path: path, errorNumber: EINVAL)
        }
    }

    static func restrictFile(at path: String) throws {
        let parent = try directory(at: (path as NSString).deletingLastPathComponent, create: false)
        defer { _ = close(parent) }
        try restrictFile((path as NSString).lastPathComponent, in: parent, path: path)
    }

    private static func restrictFile(_ name: String, in parent: CInt, path: String, ownedBy owner: uid_t? = nil) throws
    {
        if let owner {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw failure("inspect staging owner", path)
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                throw DurableFileWriteError(
                    operation: "refuse non-private regular file", path: path, errorNumber: EINVAL)
            }
            // Match the writer's ownership rule, including unreadable foreign
            // files: do not open or chmod another account's crash candidate.
            guard info.st_uid == owner else { return }
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("open state file", path) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("inspect state file", path) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            throw DurableFileWriteError(operation: "refuse non-private regular file", path: path, errorNumber: EINVAL)
        }
        if let owner, info.st_uid != owner { return }
        try restrict(descriptor, mode: 0o600, path: path)
    }

    private static func directory(at path: String, create: Bool) throws -> CInt {
        #if os(macOS)
        // macOS ships these root-owned aliases. Expand only system aliases;
        // arbitrary managed-path symlinks must still be rejected.
        var path = path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        #endif
        var descriptor = open(path.hasPrefix("/") ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("open state ancestor", path) }
        do {
            for component in path.split(separator: "/").map(String.init) {
                guard component != ".." else {
                    throw DurableFileWriteError(operation: "refuse parent traversal", path: path, errorNumber: EINVAL)
                }
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                        throw failure("create state directory", path)
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("open state directory", path) }
                _ = close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func restrict(_ descriptor: CInt, mode: mode_t, path: String) throws {
        guard fchmod(descriptor, mode) == 0 else { throw failure("restrict state permissions", path) }
    }

    private static func failure(_ operation: String, _ path: String) -> DurableFileWriteError {
        DurableFileWriteError(operation: operation, path: path, errorNumber: errno)
    }
}
