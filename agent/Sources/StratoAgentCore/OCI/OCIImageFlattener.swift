import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Flattens an OCI image's ordered layer tars into a single root tree,
/// applying OCI whiteouts (`.wh.<name>` removes the lower-layer entry,
/// `.wh..wh..opq` makes a directory opaque) as each layer lands.
///
/// Untrusted-content safety: layer archives come from arbitrary registries,
/// so no entry may write outside the root tree. Entry names containing `..`
/// are rejected outright, and parent components that turn out to be symlinks
/// are resolved *within the root* (an absolute symlink target is interpreted
/// as root-relative, the way it will resolve inside the guest) so a malicious
/// `etc -> /../../host` link can never redirect a later entry onto the host
/// filesystem.
///
/// Ownership is applied only when running as root (production agents; the
/// staged tree's uids/gids are what `mkfs.ext4 -d` copies into the image).
/// Unprivileged runs — macOS dev hosts, tests — skip chown and keep
/// everything else. Device nodes are always skipped: modern images don't
/// carry them and the sandbox guest mounts devtmpfs (issue #419).
///
/// Directory permissions are deferred to `finalize()`: a layer can ship a
/// read-only directory whose children arrive later in the stream (or in a
/// later layer), so modes are recorded during unpack — directories are
/// created owner-traversable — and applied deepest-first at the end.
public final class OCIImageFlattener {
    private let rootPath: String
    private let logger: Logger
    private let applyOwnership: Bool

    /// Final directory modes/ownership, keyed by absolute path.
    private var deferredDirectories: [String: (mode: UInt16, uid: Int, gid: Int)] = [:]

    private static let opaqueWhiteout = ".wh..wh..opq"
    private static let whiteoutPrefix = ".wh."
    private static let maxSymlinkHops = 40

    public init(rootPath: String, logger: Logger, applyOwnership: Bool = geteuid() == 0) throws {
        self.rootPath = rootPath
        self.logger = logger
        self.applyOwnership = applyOwnership
        try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
    }

    /// Applies one layer tar (already decompressed) on top of the tree.
    public func apply(layerTarPath: String) throws {
        let reader = try TarArchiveReader(path: layerTarPath)
        while let entry = try reader.nextEntry() {
            try apply(entry: entry, reader: reader)
        }
    }

    /// Applies the deferred directory modes. Call once after the last layer.
    public func finalize() throws {
        // Deepest paths first, so a directory that removes its own traverse
        // bit is finalized after everything inside it.
        let ordered = deferredDirectories.sorted {
            $0.key.split(separator: "/").count > $1.key.split(separator: "/").count
        }
        for (path, attributes) in ordered {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }  // replaced by a non-directory in a later layer
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(attributes.mode)], ofItemAtPath: path)
            changeOwner(path: path, uid: attributes.uid, gid: attributes.gid)
        }
        deferredDirectories.removeAll()
    }

    // MARK: - Entry application

    private func apply(entry: TarEntry, reader: TarArchiveReader) throws {
        let components = pathComponents(of: entry.name)
        guard !components.contains("..") else {
            throw OCIError.layerUnpackFailed(detail: "entry '\(entry.name)' attempts path traversal")
        }

        guard let name = components.last else {
            // The root entry ("./"): record its mode for finalize.
            if entry.type == .directory {
                deferredDirectories[rootPath] = (entry.mode, entry.uid, entry.gid)
            }
            return
        }

        let parentPath = try resolvedDirectory(components.dropLast())
        try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)

        // Whiteouts are metadata for lower layers, never real files.
        if name == Self.opaqueWhiteout {
            for child in (try? FileManager.default.contentsOfDirectory(atPath: parentPath)) ?? [] {
                try? FileManager.default.removeItem(atPath: parentPath + "/" + child)
            }
            return
        }
        if name.hasPrefix(Self.whiteoutPrefix) {
            let target = parentPath + "/" + String(name.dropFirst(Self.whiteoutPrefix.count))
            try? FileManager.default.removeItem(atPath: target)
            return
        }

        let path = parentPath + "/" + name

        switch entry.type {
        case .directory:
            try replaceUnlessDirectory(at: path)
            if !FileManager.default.fileExists(atPath: path) {
                // Owner-traversable during unpack; the real mode lands in
                // finalize().
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: Int(entry.mode | 0o700)])
            }
            deferredDirectories[path] = (entry.mode, entry.uid, entry.gid)

        case .file:
            try removeExisting(at: path)
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw OCIError.layerUnpackFailed(detail: "cannot create file at \(path)")
            }
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw OCIError.layerUnpackFailed(detail: "cannot open file for writing at \(path)")
            }
            do {
                try reader.readContent { chunk in
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(entry.mode)], ofItemAtPath: path)
            changeOwner(path: path, uid: entry.uid, gid: entry.gid)

        case .symbolicLink:
            try removeExisting(at: path)
            // The target is guest-side data, stored verbatim — it resolves
            // inside the booted rootfs, not on this host. Containment during
            // unpack is enforced where links are *followed* (parent
            // resolution above), not where they are created.
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: entry.linkName)
            changeOwner(path: path, uid: entry.uid, gid: entry.gid, ofSymlink: true)

        case .hardLink:
            let targetComponents = pathComponents(of: entry.linkName)
            guard !targetComponents.contains(".."), let targetName = targetComponents.last else {
                throw OCIError.layerUnpackFailed(
                    detail: "hardlink '\(entry.name)' has unsafe target '\(entry.linkName)'")
            }
            let targetPath = try resolvedDirectory(targetComponents.dropLast()) + "/" + targetName
            guard FileManager.default.fileExists(atPath: targetPath) else {
                throw OCIError.layerUnpackFailed(
                    detail: "hardlink '\(entry.name)' targets missing '\(entry.linkName)'")
            }
            try removeExisting(at: path)
            try FileManager.default.linkItem(atPath: targetPath, toPath: path)

        case .fifo:
            try removeExisting(at: path)
            guard mkfifo(path, mode_t(entry.mode)) == 0 else {
                throw OCIError.layerUnpackFailed(detail: "mkfifo failed for \(entry.name) (errno \(errno))")
            }
            changeOwner(path: path, uid: entry.uid, gid: entry.gid)

        case .characterDevice, .blockDevice:
            logger.debug(
                "Skipping device node in layer (guest mounts devtmpfs)",
                metadata: ["entry": .string(entry.name)])

        case .unsupported(let typeFlag):
            logger.warning(
                "Skipping unsupported tar entry type",
                metadata: ["entry": .string(entry.name), "typeFlag": .stringConvertible(typeFlag)])
        }
    }

    // MARK: - Path containment

    private func pathComponents(of name: String) -> [String] {
        name.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
    }

    /// Resolves a chain of directory components under the root, following
    /// symlinks *within the root only* (absolute targets are re-anchored at
    /// the root, `..` pops but never past the root). Returns the resulting
    /// absolute directory path.
    private func resolvedDirectory(_ components: ArraySlice<String>) throws -> String {
        var resolved: [String] = []
        var pending = Array(components.reversed())
        var hops = 0

        while let component = pending.popLast() {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else {
                    throw OCIError.layerUnpackFailed(detail: "symlink resolution escapes the rootfs")
                }
                resolved.removeLast()
                continue
            }

            let candidate = rootPath + "/" + (resolved + [component]).joined(separator: "/")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                guard hops <= Self.maxSymlinkHops else {
                    throw OCIError.layerUnpackFailed(detail: "symlink loop while resolving '\(component)'")
                }
                if target.hasPrefix("/") {
                    resolved = []
                }
                pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
                continue
            }
            resolved.append(component)
        }

        return resolved.isEmpty ? rootPath : rootPath + "/" + resolved.joined(separator: "/")
    }

    // MARK: - Filesystem helpers

    /// Removes whatever exists at `path` (recursively for directories) so a
    /// new non-directory entry can land there.
    private func removeExisting(at path: String) throws {
        if itemExists(at: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// For directory entries: an existing directory is kept (its metadata is
    /// re-recorded), anything else is removed.
    private func replaceUnlessDirectory(at path: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        // fileExists follows symlinks; a symlink at the path must itself be
        // replaced even when it points at a directory.
        let isSymlink =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        if (exists && !isDirectory.boolValue) || isSymlink {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// `fileExists` follows symlinks and reports false for dangling ones;
    /// check the link itself too.
    private func itemExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func changeOwner(path: String, uid: Int, gid: Int, ofSymlink: Bool = false) {
        guard applyOwnership else { return }
        // Best-effort: a failed chown is logged, not fatal, so dev setups
        // with partial privileges still materialize a usable tree.
        let result = path.withCString { cPath in
            ofSymlink ? lchown(cPath, uid_t(uid), gid_t(gid)) : chown(cPath, uid_t(uid), gid_t(gid))
        }
        if result != 0 {
            logger.debug(
                "chown failed during layer unpack",
                metadata: ["path": .string(path), "errno": .stringConvertible(errno)])
        }
    }
}
