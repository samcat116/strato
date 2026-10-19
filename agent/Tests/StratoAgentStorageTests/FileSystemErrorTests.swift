import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Filesystem error classification")
struct FileSystemErrorTests {
    private func wrapped(_ error: any Error) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: error])
    }

    @Test("Missing files remain distinguishable from unreadable stores")
    func missingFiles() {
        for error in [
            POSIXError(.ENOENT) as any Error,
            CocoaError(.fileNoSuchFile),
            CocoaError(.fileReadNoSuchFile),
        ] {
            #expect(FileSystemError.isFileNotFound(error))
            #expect(FileSystemError.isFileNotFound(wrapped(wrapped(error))))
            #expect(!FileSystemError.isInsufficientDiskSpace(error))
        }
    }

    @Test("Disk-full failures include durable writes through nested wrappers")
    func diskFull() {
        for error in [
            POSIXError(.ENOSPC) as any Error,
            CocoaError(.fileWriteOutOfSpace),
            DurableFileWriteError(
                operation: "synchronize", path: "/volume", errorNumber: POSIXErrorCode.ENOSPC.rawValue),
        ] {
            #expect(FileSystemError.isInsufficientDiskSpace(error))
            #expect(FileSystemError.isInsufficientDiskSpace(wrapped(wrapped(error))))
            #expect(!FileSystemError.isFileNotFound(error))
        }
    }

    @Test("Permission and IO failures retain their original failure semantics")
    func otherFailures() {
        for error in [POSIXError(.EACCES), POSIXError(.EIO), POSIXError(.EMFILE)] {
            #expect(!FileSystemError.isFileNotFound(wrapped(error)))
            #expect(!FileSystemError.isInsufficientDiskSpace(wrapped(error)))
        }
    }
}
