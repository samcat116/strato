#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

/// The POSIX boundary used by ``DurableFileWriter``.
///
/// Kept injectable because the durability contract is an ordering contract:
/// file data must reach stable storage before its name is published, and the
/// containing directory must reach stable storage afterwards.
protocol DurableFileSystemCalls: Sendable {
    var errorNumber: CInt { get }

    func pathStatus(at path: String) -> DurablePathStatus
    func createDirectory(at path: String, permissions: CInt) -> CInt
    func removeItem(at path: String) -> CInt
    func createFile(at path: String, permissions: CInt) -> CInt
    func openDirectoryForSynchronization(at path: String) -> CInt
    func write(_ data: Data, to fileDescriptor: CInt) throws
    func synchronizeFile(_ fileDescriptor: CInt, at path: String) throws
    func synchronizeFile(at path: String) throws
    func directoryEntries(at path: String) throws -> [DurableDirectoryEntry]
    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt
    func close(_ fileDescriptor: CInt) -> CInt
    func replaceItem(at destination: String, withItemAt source: String) -> CInt
}

struct DurableDirectoryEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        case unsupported
    }

    let path: String
    let kind: Kind
}

enum DurablePathStatus: Sendable, Equatable {
    case missing
    case directory
    case other
    case failure(errorNumber: CInt)
}

/// Atomically publishes files with power-loss durability.
///
/// An atomic rename only protects readers from observing an in-progress
/// write. The file data is synchronized before the rename, and the destination
/// directory is synchronized after it, so an acknowledged save also survives
/// an unclean host shutdown.
struct DurableFileWriter: Sendable {
    private let systemCalls: any DurableFileSystemCalls

    init(systemCalls: any DurableFileSystemCalls = POSIXDurableFileSystemCalls()) {
        self.systemCalls = systemCalls
    }

    /// Writes `data` to a same-directory temporary file and durably replaces
    /// `path`. `permissions` is applied when the temporary file is created and
    /// is therefore never wider while its contents are present.
    func write(_ data: Data, to path: String, permissions: CInt = 0o666) throws {
        try createDirectory(at: parentDirectory(of: path))

        let temporaryPath = path + ".tmp"
        _ = systemCalls.removeItem(at: temporaryPath)

        let fileDescriptor = systemCalls.createFile(at: temporaryPath, permissions: permissions)
        guard fileDescriptor >= 0 else {
            throw error(operation: "open", path: temporaryPath)
        }

        var descriptorIsOpen = true
        var temporaryFileExists = true
        do {
            try systemCalls.write(data, to: fileDescriptor)
            try systemCalls.synchronizeFile(fileDescriptor, at: temporaryPath)

            let closeResult = systemCalls.close(fileDescriptor)
            descriptorIsOpen = false
            try requireSuccess(closeResult, operation: "close", path: temporaryPath)

            try requireSuccess(
                systemCalls.replaceItem(at: path, withItemAt: temporaryPath),
                operation: "rename", path: path)
            temporaryFileExists = false

            try synchronizeParentDirectory(of: path)
        } catch {
            if descriptorIsOpen {
                _ = systemCalls.close(fileDescriptor)
            }
            if temporaryFileExists {
                _ = systemCalls.removeItem(at: temporaryPath)
            }
            throw error
        }
    }

    /// Creates a directory and any missing ancestors, synchronizing each new
    /// directory through its parent before returning.
    ///
    /// Synchronizing a new directory's own descriptor persists entries inside
    /// it, but not the directory's name in its parent. Creating top-down and
    /// synchronizing each parent closes that separate power-loss window.
    func createDirectory(at path: String) throws {
        // Preserve lexical `.` and `..` components. The kernel cannot resolve
        // `missing/..` until `missing` exists, so normalizing the path first
        // would skip a directory that callers still need in the original path.
        let directoryPath = path.isEmpty ? "." : path
        var missingDirectories: [String] = []
        var candidate = directoryPath

        while true {
            switch systemCalls.pathStatus(at: candidate) {
            case .directory:
                break
            case .missing:
                missingDirectories.append(candidate)
                let parent = parentDirectory(of: candidate)
                guard parent != candidate else {
                    throw DurableFileWriteError(
                        operation: "find existing directory ancestor", path: candidate,
                        errorNumber: ENOENT)
                }
                candidate = parent
                continue
            case .other:
                throw DurableFileWriteError(
                    operation: "create directory", path: candidate, errorNumber: ENOTDIR)
            case .failure(let errorNumber):
                throw DurableFileWriteError(
                    operation: "inspect directory", path: candidate, errorNumber: errorNumber)
            }
            break
        }

        for directory in missingDirectories.reversed() {
            let result = systemCalls.createDirectory(at: directory, permissions: 0o777)
            if result != 0 {
                let errorNumber = systemCalls.errorNumber
                guard errorNumber == EEXIST, systemCalls.pathStatus(at: directory) == .directory else {
                    throw DurableFileWriteError(
                        operation: "create directory", path: directory, errorNumber: errorNumber)
                }
            }
            try synchronizeParentDirectory(of: directory)
        }
    }

    /// Durably publishes a complete file already staged beside `path`.
    func publish(stagingPath: String, to path: String) throws {
        try systemCalls.synchronizeFile(at: stagingPath)
        try requireSuccess(
            systemCalls.replaceItem(at: path, withItemAt: stagingPath),
            operation: "rename", path: path)
        try synchronizeParentDirectory(of: path)
    }

    /// Durably publishes a complete directory already staged beside `path`.
    ///
    /// Every regular file is synchronized before the directory entries that
    /// name it, then the staged directory is renamed and its parent is
    /// synchronized. Symlinks and special files are rejected: following one
    /// while synchronizing could flush content outside the staged tree.
    ///
    /// When `completionFileName` is supplied, that direct child is
    /// synchronized after every other payload file. This lets a cache use a
    /// small sidecar as durable proof that all payload bytes preceded it.
    func publishDirectory(
        stagingPath: String, to path: String, completionFileName: String? = nil
    ) throws {
        let entries = try systemCalls.directoryEntries(at: stagingPath)
        let completionPath: String?
        if let completionFileName {
            guard !completionFileName.isEmpty,
                completionFileName != ".",
                completionFileName != "..",
                !(completionFileName as NSString).isAbsolutePath,
                !completionFileName.contains("/")
            else {
                throw DurableFileWriteError(
                    operation: "validate completion file", path: completionFileName,
                    errorNumber: EINVAL)
            }
            completionPath = stagingPath + "/" + completionFileName
            guard entries.contains(where: { $0.path == completionPath && $0.kind == .file }) else {
                throw DurableFileWriteError(
                    operation: "find completion file", path: completionPath!, errorNumber: ENOENT)
            }
        } else {
            completionPath = nil
        }

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            switch entry.kind {
            case .file where entry.path != completionPath:
                try systemCalls.synchronizeFile(at: entry.path)
            case .file, .directory:
                break
            case .unsupported:
                throw DurableFileWriteError(
                    operation: "synchronize unsupported directory entry", path: entry.path,
                    errorNumber: EINVAL)
            }
        }

        // Persist nested directory entries from the leaves upward before the
        // staging directory's own entry set is synchronized.
        let directories = entries.filter { $0.kind == .directory }.sorted {
            let lhsDepth = $0.path.split(separator: "/").count
            let rhsDepth = $1.path.split(separator: "/").count
            return lhsDepth == rhsDepth ? $0.path < $1.path : lhsDepth > rhsDepth
        }
        for directory in directories {
            try synchronizeDirectory(at: directory.path)
        }
        if let completionPath {
            try systemCalls.synchronizeFile(at: completionPath)
        }
        try synchronizeDirectory(at: stagingPath)

        try requireSuccess(
            systemCalls.replaceItem(at: path, withItemAt: stagingPath),
            operation: "rename", path: path)
        try synchronizeParentDirectory(of: path)
    }

    private func synchronizeParentDirectory(of path: String) throws {
        try synchronizeDirectory(at: parentDirectory(of: path))
    }

    private func synchronizeDirectory(at directoryPath: String) throws {
        let directoryDescriptor = systemCalls.openDirectoryForSynchronization(at: directoryPath)
        guard directoryDescriptor >= 0 else {
            throw error(operation: "open directory", path: directoryPath)
        }

        var descriptorIsOpen = true
        do {
            try requireSuccess(
                systemCalls.synchronizeDirectory(directoryDescriptor),
                operation: "synchronize directory", path: directoryPath)

            let closeResult = systemCalls.close(directoryDescriptor)
            descriptorIsOpen = false
            try requireSuccess(closeResult, operation: "close directory", path: directoryPath)
        } catch {
            if descriptorIsOpen {
                _ = systemCalls.close(directoryDescriptor)
            }
            throw error
        }
    }

    private func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    private func requireSuccess(_ result: CInt, operation: String, path: String) throws {
        guard result == 0 else { throw error(operation: operation, path: path) }
    }

    private func error(operation: String, path: String) -> DurableFileWriteError {
        DurableFileWriteError(operation: operation, path: path, errorNumber: systemCalls.errorNumber)
    }
}

struct DurableFileWriteError: Error, CustomStringConvertible {
    let operation: String
    let path: String
    let errorNumber: CInt

    var description: String {
        "\(operation) \(path) failed: \(String(cString: strerror(errorNumber))) (errno \(errorNumber))"
    }
}

private struct POSIXDurableFileSystemCalls: DurableFileSystemCalls {
    var errorNumber: CInt { errno }

    func pathStatus(at path: String) -> DurablePathStatus {
        var information = stat()
        let result = path.withCString { pointer in
            stat(pointer, &information)
        }
        if result == 0 {
            return information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? .directory : .other
        }
        return errno == ENOENT ? .missing : .failure(errorNumber: errno)
    }

    func createDirectory(at path: String, permissions: CInt) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.mkdir(path, mode_t(permissions))
            #else
            Darwin.mkdir(path, mode_t(permissions))
            #endif
        }
    }

    func removeItem(at path: String) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.unlink(path)
            #else
            Darwin.unlink(path)
            #endif
        }
    }

    func createFile(at path: String, permissions: CInt) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(permissions))
            #else
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(permissions))
            #endif
        }
    }

    func openDirectoryForSynchronization(at path: String) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            #else
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            #endif
        }
    }

    func write(_ data: Data, to fileDescriptor: CInt) throws {
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written: Int
                #if canImport(Glibc)
                written = Glibc.write(fileDescriptor, cursor, remaining)
                #else
                written = Darwin.write(fileDescriptor, cursor, remaining)
                #endif

                if written < 0 {
                    if errno == EINTR { continue }
                    throw DurableFileWriteError(
                        operation: "write", path: "file descriptor \(fileDescriptor)", errorNumber: errno)
                }
                guard written > 0 else {
                    throw DurableFileWriteError(
                        operation: "write", path: "file descriptor \(fileDescriptor)", errorNumber: EIO)
                }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    func synchronizeFile(_ fileDescriptor: CInt, at path: String) throws {
        #if canImport(Darwin)
        // Foundation's synchronize() uses fsync(2), which does not drain a
        // drive's volatile write cache on macOS.
        guard retryOnInterrupt({ Darwin.fcntl(fileDescriptor, F_FULLFSYNC) }) == 0 else {
            throw DurableFileWriteError(
                operation: "synchronize", path: path, errorNumber: errno)
        }
        #else
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        try handle.synchronize()
        #endif
    }

    func synchronizeFile(at path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        do {
            try synchronizeFile(handle.fileDescriptor, at: path)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    func directoryEntries(at path: String) throws -> [DurableDirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var entries: [DurableDirectoryEntry] = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: path) {
            // Keep the caller's lexical root instead of URL's canonicalized
            // `/private/var` spelling so completion-file ordering can compare
            // exact paths even when macOS reaches /tmp through a symlink.
            let entryPath = path + "/" + relativePath
            let url = URL(fileURLWithPath: entryPath)
            let values = try url.resourceValues(forKeys: Set(keys))
            let kind: DurableDirectoryEntry.Kind
            if values.isSymbolicLink == true {
                kind = .unsupported
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                kind = .unsupported
            }
            entries.append(DurableDirectoryEntry(path: entryPath, kind: kind))
        }
        return entries
    }

    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.fsync(fileDescriptor)
            #else
            // Like file contents, renamed directory entries must be forced
            // through the drive's volatile write cache on macOS.
            Darwin.fcntl(fileDescriptor, F_FULLFSYNC)
            #endif
        }
    }

    func close(_ fileDescriptor: CInt) -> CInt {
        #if canImport(Glibc)
        Glibc.close(fileDescriptor)
        #else
        Darwin.close(fileDescriptor)
        #endif
    }

    func replaceItem(at destination: String, withItemAt source: String) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.rename(source, destination)
            #else
            Darwin.rename(source, destination)
            #endif
        }
    }

    private func retryOnInterrupt(_ operation: () -> CInt) -> CInt {
        var result: CInt
        repeat {
            result = operation()
        } while result < 0 && errno == EINTR
        return result
    }
}
