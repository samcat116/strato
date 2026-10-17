import Foundation

/// Classifies filesystem failures through Foundation's nested error wrappers.
public enum FileSystemError {
    public static func isFileNotFound(_ error: any Error) -> Bool {
        matches(error) { error in
            let error = error as NSError
            return
                (error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
                || (error.domain == NSPOSIXErrorDomain && error.code == POSIXErrorCode.ENOENT.rawValue)
        }
    }

    public static func isInsufficientDiskSpace(_ error: any Error) -> Bool {
        matches(error) { error in
            if let error = error as? DurableFileWriteError,
                error.errorNumber == POSIXErrorCode.ENOSPC.rawValue
            {
                return true
            }
            let error = error as NSError
            return (error.domain == NSPOSIXErrorDomain && error.code == POSIXErrorCode.ENOSPC.rawValue)
                || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
        }
    }

    private static func matches(_ error: any Error, predicate: (any Error) -> Bool) -> Bool {
        var current = error
        while true {
            if predicate(current) { return true }
            guard let underlying = (current as NSError).userInfo[NSUnderlyingErrorKey] as? any Error else {
                return false
            }
            current = underlying
        }
    }
}
