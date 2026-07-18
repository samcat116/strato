import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// AF_UNIX `sun_path` is a fixed ~104/108-byte buffer, but a jailed
/// Firecracker's sockets (issue #425) live at host paths like
/// `<chroot base>/<exec name>/<vm id>/root/run/firecracker.socket` that can
/// exceed it with a long storage directory or a versioned binary name. On
/// Linux the classic escape hatch applies: hold an fd on the socket's parent
/// directory and connect through the short, stable
/// `/proc/self/fd/<fd>/<basename>` alias, which the kernel resolves to the
/// same inode. Every AF_UNIX connect in this package goes through here so no
/// call site re-grows the length limit.
enum UnixSocketPath {
    struct Connectable {
        /// The path to copy into `sun_path`.
        let path: String
        /// The parent-directory fd backing a `/proc/self/fd` alias, or nil
        /// when `path` fit directly. The caller closes it once the connect
        /// attempt has finished — the alias is only valid while it is open.
        let dirFD: Int32?

        /// Closes the backing fd, if any. Idempotence is the caller's concern
        /// (call exactly once, after connect succeeds or fails).
        func closeDirFD() {
            if let dirFD { close(dirFD) }
        }
    }

    /// Returns `path` itself when it fits `capacity` (leaving room for the
    /// trailing NUL), else a `/proc/self/fd` alias on Linux. Throws when the
    /// path cannot be represented at all (macOS overlong path — jailed
    /// layouts do not exist there — or an unopenable parent directory).
    static func connectable(path: String, capacity: Int) throws -> Connectable {
        if path.utf8.count < capacity {
            return Connectable(path: path, dirFD: nil)
        }
        #if os(Linux)
        let url = URL(fileURLWithPath: path)
        let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else {
            throw FirecrackerError.invalidSocketPath(
                "Socket path is \(path.utf8.count) bytes (sun_path holds \(capacity - 1)) and its parent directory could not be opened for /proc/self/fd indirection (errno \(errno)): \(path)"
            )
        }
        let alias = "/proc/self/fd/\(dirFD)/\(url.lastPathComponent)"
        guard alias.utf8.count < capacity else {
            close(dirFD)
            throw FirecrackerError.invalidSocketPath(
                "Socket basename alone exceeds sun_path even via /proc/self/fd: \(path)")
        }
        return Connectable(path: alias, dirFD: dirFD)
        #else
        throw FirecrackerError.invalidSocketPath(
            "Socket path is \(path.utf8.count) bytes; must be < \(capacity): \(path)")
        #endif
    }
}
