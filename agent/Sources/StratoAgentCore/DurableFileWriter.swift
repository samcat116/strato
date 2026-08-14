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

    func removeItem(at path: String) -> CInt
    func createFile(at path: String, permissions: CInt) -> CInt
    func openFileForSynchronization(at path: String) -> CInt
    func openDirectoryForSynchronization(at path: String) -> CInt
    func write(_ data: Data, to fileDescriptor: CInt) throws
    func synchronizeFile(_ fileDescriptor: CInt) -> CInt
    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt
    func close(_ fileDescriptor: CInt) -> CInt
    func replaceItem(at destination: String, withItemAt source: String) -> CInt
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
            try requireSuccess(
                systemCalls.synchronizeFile(fileDescriptor), operation: "synchronize", path: temporaryPath)

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

    /// Durably publishes a complete file already staged beside `path`.
    func publish(stagingPath: String, to path: String) throws {
        let fileDescriptor = systemCalls.openFileForSynchronization(at: stagingPath)
        guard fileDescriptor >= 0 else {
            throw error(operation: "open", path: stagingPath)
        }

        var descriptorIsOpen = true
        do {
            try requireSuccess(
                systemCalls.synchronizeFile(fileDescriptor), operation: "synchronize", path: stagingPath)

            let closeResult = systemCalls.close(fileDescriptor)
            descriptorIsOpen = false
            try requireSuccess(closeResult, operation: "close", path: stagingPath)

            try requireSuccess(
                systemCalls.replaceItem(at: path, withItemAt: stagingPath),
                operation: "rename", path: path)
            try synchronizeParentDirectory(of: path)
        } catch {
            if descriptorIsOpen {
                _ = systemCalls.close(fileDescriptor)
            }
            throw error
        }
    }

    private func synchronizeParentDirectory(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let directoryPath = parent.isEmpty ? "." : parent
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

    func openFileForSynchronization(at path: String) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.open(path, O_RDWR | O_CLOEXEC)
            #else
            Darwin.open(path, O_RDWR | O_CLOEXEC)
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

    func synchronizeFile(_ fileDescriptor: CInt) -> CInt {
        retryOnInterrupt {
            #if canImport(Darwin)
            // fsync(2) does not drain a drive's volatile write cache on macOS.
            Darwin.fcntl(fileDescriptor, F_FULLFSYNC)
            #else
            Glibc.fsync(fileDescriptor)
            #endif
        }
    }

    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt {
        retryOnInterrupt {
            #if canImport(Glibc)
            Glibc.fsync(fileDescriptor)
            #else
            Darwin.fsync(fileDescriptor)
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
