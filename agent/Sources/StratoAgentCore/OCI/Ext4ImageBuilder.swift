import Foundation
import Logging

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
        self.mkfsPath = mkfsPath
        self.headroomFraction = headroomFraction
        self.minimumHeadroomBytes = minimumHeadroomBytes
        self.minimumImageBytes = minimumImageBytes
        self.logger = logger
        self.runSubprocess = runSubprocess
    }

    public func buildImage(fromTree treePath: String, at imagePath: String) async throws {
        let mkfs = try resolveMkfs()
        let sizeBytes = imageSizeBytes(forTree: treePath)

        // Pre-size the image file; mkfs formats to the existing size.
        FileManager.default.createFile(atPath: imagePath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: imagePath) else {
            throw OCIError.hostMisconfiguration(detail: "cannot create rootfs image at \(imagePath)")
        }
        do {
            try handle.truncate(atOffset: UInt64(sizeBytes))
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: imagePath)
            throw error
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
}
