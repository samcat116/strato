import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Builds the sandbox rootfs image from a flattened tree. Protocol-typed so
/// the materialization pipeline is testable on hosts without mkfs.ext4
/// (macOS, CI containers).
public protocol RootfsImageBuilder: Sendable {
    /// Writes a root filesystem image containing `treePath`'s contents to
    /// `imagePath` (creating or replacing it). The caller owns staging and
    /// atomic publication of `imagePath`.
    func buildImage(fromTree treePath: String, at imagePath: String) async throws
}

/// ext4 via `mkfs.ext4 -d`: e2fsprogs populates the filesystem directly from
/// the staged tree (ownership, modes, symlinks and hardlinks preserved), no
/// loop mounts and no root required beyond what the unpack already used. The
/// image is sized to the tree's content plus configurable headroom, so the
/// guest has scratch space without ballooning the cache.
public struct Ext4ImageBuilder: RootfsImageBuilder {
    /// Free-space headroom as a fraction of content size.
    public var headroomFraction: Double
    /// Headroom floor, so tiny images still get usable scratch space.
    public var minimumHeadroomBytes: Int64
    /// Smallest image ever produced (ext4 itself needs room for metadata).
    public var minimumImageBytes: Int64

    private let mkfsPath: String?
    private let logger: Logger
    private let runSubprocess: SubprocessRunner
    private let prepareImage: @Sendable (String, UInt64) throws -> Void

    private static let mkfsCandidates = ["/usr/sbin/mkfs.ext4", "/sbin/mkfs.ext4", "/usr/bin/mkfs.ext4"]
    private static let blockSize: Int64 = 4096

    public init(
        mkfsPath: String? = nil,
        headroomFraction: Double = 0.25,
        minimumHeadroomBytes: Int64 = 32 * 1024 * 1024,
        minimumImageBytes: Int64 = 64 * 1024 * 1024,
        logger: Logger,
        runSubprocess: @escaping SubprocessRunner = {
            try await ProcessRunner.run(executableURL: $0, arguments: $1)
        }
    ) {
        self.init(
            mkfsPath: mkfsPath,
            headroomFraction: headroomFraction,
            minimumHeadroomBytes: minimumHeadroomBytes,
            minimumImageBytes: minimumImageBytes,
            logger: logger,
            runSubprocess: runSubprocess,
            prepareImage: Self.prepareImage)
    }

    init(
        mkfsPath: String? = nil,
        headroomFraction: Double = 0.25,
        minimumHeadroomBytes: Int64 = 32 * 1024 * 1024,
        minimumImageBytes: Int64 = 64 * 1024 * 1024,
        logger: Logger,
        runSubprocess: @escaping SubprocessRunner = {
            try await ProcessRunner.run(executableURL: $0, arguments: $1)
        },
        prepareImage: @escaping @Sendable (String, UInt64) throws -> Void
    ) {
        self.mkfsPath = mkfsPath
        self.headroomFraction = headroomFraction
        self.minimumHeadroomBytes = minimumHeadroomBytes
        self.minimumImageBytes = minimumImageBytes
        self.logger = logger
        self.runSubprocess = runSubprocess
        self.prepareImage = prepareImage
    }

    public func buildImage(fromTree treePath: String, at imagePath: String) async throws {
        let mkfs = try resolveMkfs()
        let sizeBytes = imageSizeBytes(forTree: treePath)

        // Pre-size the image file; mkfs formats to the existing size.
        do {
            try prepareImage(imagePath, UInt64(sizeBytes))
        } catch {
            try? FileManager.default.removeItem(atPath: imagePath)
            guard Self.isInsufficientDiskSpace(error) else { throw error }
            throw OCIError.insufficientDiskSpace(
                detail: "pre-sizing the rootfs image at \(imagePath) ran out of space. "
                    + "Free disk space or inodes, then retry.")
        }

        logger.info(
            "Building ext4 rootfs image",
            metadata: [
                "tree": .string(treePath),
                "image": .string(imagePath),
                "sizeBytes": .stringConvertible(sizeBytes),
            ])

        let result = try await runSubprocess(
            URL(fileURLWithPath: mkfs), ["-F", "-q", "-d", treePath, imagePath])
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: imagePath)
            if result.combinedOutput.localizedCaseInsensitiveContains("No space left on device") {
                throw OCIError.insufficientDiskSpace(
                    detail: "mkfs.ext4 ran out of space while populating \(imagePath). "
                        + "Free disk space or inodes, then retry. Output: \(result.combinedOutput)")
            }
            throw OCIError.hostMisconfiguration(
                detail: "mkfs.ext4 exited \(result.terminationStatus): \(result.combinedOutput)")
        }
    }

    /// Content bytes rounded to filesystem blocks, one block of slack per
    /// entry for inodes/directory entries, plus headroom — a heuristic, so
    /// headroom absorbs estimation error as well as guest scratch writes.
    func imageSizeBytes(forTree treePath: String) -> Int64 {
        var contentBytes: Int64 = 0
        var entryCount: Int64 = 1  // the root directory itself

        if let enumerator = FileManager.default.enumerator(atPath: treePath) {
            while let relative = enumerator.nextObject() as? String {
                entryCount += 1
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: treePath + "/" + relative)
                guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular,
                    let size = attributes[.size] as? Int64
                else { continue }
                contentBytes += (size + Self.blockSize - 1) / Self.blockSize * Self.blockSize
            }
        }

        let withMetadata = contentBytes + entryCount * Self.blockSize
        let headroom = max(Int64(Double(withMetadata) * headroomFraction), minimumHeadroomBytes)
        let total = max(withMetadata + headroom, minimumImageBytes)
        return (total + Self.blockSize - 1) / Self.blockSize * Self.blockSize
    }

    private func resolveMkfs() throws -> String {
        if let mkfsPath {
            guard FileManager.default.isExecutableFile(atPath: mkfsPath) else {
                throw OCIError.hostMisconfiguration(detail: "mkfs.ext4 not executable at \(mkfsPath)")
            }
            return mkfsPath
        }
        if let found = Self.mkfsCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw OCIError.hostMisconfiguration(
            detail: "mkfs.ext4 not found (looked in \(Self.mkfsCandidates.joined(separator: ", "))); "
                + "install e2fsprogs to materialize sandbox root filesystems")
    }

    private static func prepareImage(at path: String, sizeBytes: UInt64) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            if errno == ENOSPC { throw POSIXError(.ENOSPC) }
            throw OCIError.hostMisconfiguration(detail: "cannot create rootfs image at \(path)")
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw OCIError.hostMisconfiguration(detail: "cannot create rootfs image at \(path)")
        }
        do {
            try handle.truncate(atOffset: sizeBytes)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Foundation can wrap POSIX write failures in one or more Cocoa errors.
    private static func isInsufficientDiskSpace(_ error: Error) -> Bool {
        var current: any Error = error
        while true {
            let candidate = current as NSError
            if candidate.domain == NSPOSIXErrorDomain,
                candidate.code == POSIXErrorCode.ENOSPC.rawValue
            {
                return true
            }
            if candidate.domain == NSCocoaErrorDomain,
                candidate.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
            {
                return true
            }
            guard let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? any Error else {
                return false
            }
            current = underlying
        }
    }
}
