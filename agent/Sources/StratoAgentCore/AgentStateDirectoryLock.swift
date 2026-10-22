import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Local process ownership, independent of control-plane inventory/session fencing.
/// The lock file must never be unlinked: a replacement inode would permit two owners.
public final class AgentStateDirectoryLock: Sendable {
    let descriptor: CInt

    public init(at path: String) throws {
        let directory = try ManagedStatePermissions.directory(at: path, create: true)
        defer { _ = close(directory) }
        let lockPath = (path as NSString).appendingPathComponent(".agent.lock")
        let file = openat(directory, ".agent.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            throw DurableFileWriteError(operation: "open agent ownership lock", path: lockPath, errorNumber: errno)
        }
        do {
            var info = stat()
            guard fstat(file, &info) == 0 else {
                throw DurableFileWriteError(
                    operation: "inspect agent ownership lock", path: lockPath, errorNumber: errno)
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1, info.st_uid == geteuid() else {
                throw DurableFileWriteError(
                    operation: "refuse unsafe agent ownership lock", path: lockPath, errorNumber: EPERM)
            }
            while flock(file, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw AgentStateDirectoryInUse(path: path)
                }
                throw DurableFileWriteError(
                    operation: "acquire agent ownership lock", path: lockPath, errorNumber: errno)
            }
            // A refused contender must not change even the lock's permissions.
            guard fchmod(file, 0o600) == 0 else {
                throw DurableFileWriteError(
                    operation: "restrict agent ownership lock", path: lockPath, errorNumber: errno)
            }
        } catch {
            _ = close(file)
            throw error
        }
        descriptor = file
    }

    deinit {
        // close releases ownership on normal teardown; the kernel also releases
        // it on process death. CLOEXEC prevents guests/helpers inheriting it.
        _ = close(descriptor)
    }
}

public struct AgentStateDirectoryInUse: Error, LocalizedError, CustomStringConvertible {
    public let path: String

    public var description: String {
        "Agent state directory \(path) is already in use. "
            + "Stop the other agent process or choose a different vm_storage_path. Do not remove .agent.lock."
    }

    public var errorDescription: String? { description }
}
