#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

/// Coordinates generated staging names across processes. The exact UUID name
/// grammar is reserved to the writer; bare `.tmp` and operator suffixes are not.
struct OwnedFileCleanup {
    static func isUUID(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text)?.uuidString == text.uppercased()
    }

    static func isStagingName(_ name: String, for destination: String) -> Bool {
        let prefix = destination + ".tmp."
        return name.hasPrefix(prefix) && isUUID(String(name.dropFirst(prefix.count)))
    }

    static func lockDirectory(_ path: String, followDirectoryLink: Bool = false) throws -> CInt {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followDirectoryLink ? 0 : O_NOFOLLOW)
        let descriptor = open(path, flags)
        guard descriptor >= 0 else { throw failure("open cleanup directory", path) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = failure("lock cleanup directory", path)
            _ = close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Only unlinks direct, current-account-owned regular files with one link.
    /// `unlinkat` never follows a candidate link or a replaced directory path.
    static func removeFiles(
        in directory: String, descriptor: CInt, rejectUnsafeMatches: Bool = false,
        matching matches: (String) -> Bool
    ) throws {
        var firstError: (any Error)?
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) where matches(name) {
            var information = stat()
            if fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno != ENOENT { firstError = firstError ?? failure("inspect cleanup file", name) }
                continue
            }
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                information.st_uid == geteuid(), information.st_nlink == 1
            else {
                if rejectUnsafeMatches {
                    firstError =
                        firstError
                        ?? DurableFileWriteError(
                            operation: "refuse unsafe cleanup file", path: name, errorNumber: EPERM)
                }
                continue
            }
            if unlinkat(descriptor, name, 0) != 0, errno != ENOENT {
                firstError = firstError ?? failure("remove cleanup file", name)
            }
        }
        // Persist erasure even when a later write or libvirt command fails.
        if fsync(descriptor) != 0 { firstError = firstError ?? failure("sync cleanup directory", directory) }
        if let firstError { throw firstError }
    }

    private static func failure(_ operation: String, _ path: String) -> DurableFileWriteError {
        DurableFileWriteError(operation: operation, path: path, errorNumber: errno)
    }
}
