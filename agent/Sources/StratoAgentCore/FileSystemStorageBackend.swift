import Foundation
import Logging
import StratoShared

/// Runs a subprocess to completion. Injectable so tests can stub qemu-img.
public typealias SubprocessRunner =
    @Sendable (_ executableURL: URL, _ arguments: [String]) async throws -> ProcessResult

/// The "qemu-img on a filesystem directory" storage backend.
///
/// Owns the on-disk layout for managed volumes:
///
///     <volumeStoragePath>/<volumeId>/volume.<format>
///     <volumeStoragePath>/<volumeId>/snapshots/<snapshotId>.qcow2
///
/// and the single image → disk materialization path: sources are inspected
/// with `qemu-img info` and converted with `qemu-img convert` whenever the
/// requested format differs, so every hypervisor driver gets a correctly
/// formatted disk (a qcow2 cloud image becomes a raw rootfs for Firecracker,
/// not a byte-for-byte copy with the wrong name).
public actor FileSystemStorageBackend: StorageBackend {
    private let logger: Logger
    private let volumeStoragePath: String
    private let qemuImgPath: String
    private let imageSource: (any ImageSource)?
    private let runSubprocess: SubprocessRunner
    private let enumerateVolumeStore: @Sendable (String) throws -> [String]

    /// Default storage path for volumes (platform-specific)
    public static var defaultStoragePath: String {
        #if os(macOS)
        // On macOS, use user's data directory (writable without root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/volumes"
        #else
        // On Linux, use system data directory
        return "/var/lib/strato/volumes"
        #endif
    }

    /// Default qemu-img path (platform-specific)
    public static var defaultQemuImgPath: String {
        #if os(macOS)
        // Homebrew typically installs qemu-img here
        return "/opt/homebrew/bin/qemu-img"
        #else
        return "/usr/bin/qemu-img"
        #endif
    }

    public init(
        logger: Logger,
        volumeStoragePath: String? = nil,
        qemuImgPath: String? = nil,
        imageSource: (any ImageSource)? = nil,
        enumerateVolumeStore: @escaping @Sendable (String) throws -> [String] = {
            try FileManager.default.contentsOfDirectory(atPath: $0)
        },
        runSubprocess: @escaping SubprocessRunner = { try await ProcessRunner.run(executableURL: $0, arguments: $1) }
    ) {
        self.logger = logger
        self.volumeStoragePath = volumeStoragePath ?? Self.defaultStoragePath
        self.qemuImgPath = qemuImgPath ?? Self.defaultQemuImgPath
        self.imageSource = imageSource
        self.runSubprocess = runSubprocess
        self.enumerateVolumeStore = enumerateVolumeStore

        // Ensure storage directory exists
        do {
            try FileManager.default.createDirectory(
                atPath: self.volumeStoragePath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info(
                "Storage backend initialized",
                metadata: [
                    "storagePath": .string(self.volumeStoragePath),
                    "qemuImgPath": .string(self.qemuImgPath),
                ])
        } catch {
            logger.error(
                "Failed to create volume storage directory: \(error)",
                metadata: [
                    "storagePath": .string(self.volumeStoragePath)
                ])
        }
    }

    // MARK: - Path Layout

    /// The canonical path for a volume. The agent is the sole authority on
    /// this layout; the control plane only stores what gets reported back.
    public func volumePath(volumeId: String, format: DiskFormat) -> String {
        "\(volumeStoragePath)/\(volumeId)/volume.\(format.fileExtension)"
    }

    private func volumeDirectory(volumeId: String) -> String {
        "\(volumeStoragePath)/\(volumeId)"
    }

    private func snapshotPath(volumeId: String, snapshotId: String) -> String {
        "\(volumeStoragePath)/\(volumeId)/snapshots/\(snapshotId).qcow2"
    }

    // MARK: - Volume Creation

    public func createVolume(volumeId: String, sizeBytes: Int64, format: DiskFormat) async throws -> DiskAttachment {
        let path = volumePath(volumeId: volumeId, format: format)

        // Idempotent, like `materializeDisk`: a level-triggered sync may
        // re-drive a create whose success report was lost, and the canonical
        // path only ever holds a finished volume (see `publishAtomically`).
        if FileManager.default.fileExists(atPath: path) {
            logger.debug("Volume already exists", metadata: ["volumeId": .string(volumeId)])
            return DiskAttachment(path: path, format: format)
        }

        logger.info(
            "Creating volume",
            metadata: [
                "volumeId": .string(volumeId),
                "size": .stringConvertible(sizeBytes),
                "format": .string(format.rawValue),
            ])

        try FileManager.default.createDirectory(
            atPath: volumeDirectory(volumeId: volumeId),
            withIntermediateDirectories: true,
            attributes: nil
        )

        try await publishAtomically(to: path) { stagingPath in
            let result = try await self.runQemuImg(["create", "-f", format.rawValue, stagingPath, "\(sizeBytes)"])
            if result.terminationStatus != 0 {
                let output = result.combinedOutput
                self.logger.error(
                    "qemu-img create failed",
                    metadata: [
                        "volumeId": .string(volumeId),
                        "output": .string(output),
                    ])
                throw self.qemuImgFailure(
                    output: output, context: "qemu-img create", fallback: StorageBackendError.createFailed)
            }
        }

        logger.info(
            "Volume created successfully",
            metadata: [
                "volumeId": .string(volumeId),
                "path": .string(path),
            ])

        return DiskAttachment(path: path, format: format)
    }

    public func createVolumeFromImage(volumeId: String, imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment
    {
        logger.info(
            "Creating volume from image",
            metadata: [
                "volumeId": .string(volumeId),
                "imageId": .string(imageInfo.imageId.uuidString),
                "format": .string(format.rawValue),
            ])

        return try await materializeDisk(
            at: volumePath(volumeId: volumeId, format: format),
            from: imageInfo,
            format: format,
            artifactKind: .diskImage
        )
    }

    // MARK: - Image Materialization

    public func materializeDisk(
        at path: String, from imageInfo: ImageInfo, format: DiskFormat, artifactKind: ArtifactKind = .diskImage
    ) async throws -> DiskAttachment {
        // Idempotent: a disk already materialized for this path (e.g. a VM
        // re-create after an agent restart) is reused, not overwritten. The
        // final path only ever holds a complete disk because materialization
        // writes to a temporary path and publishes via atomic rename below —
        // an interrupted copy/convert can never satisfy this check.
        if FileManager.default.fileExists(atPath: path) {
            logger.debug("Disk already materialized", metadata: ["path": .string(path)])
            return DiskAttachment(path: path, format: format)
        }

        guard let imageSource else {
            throw StorageBackendError.imageSourceUnavailable
        }

        let sourcePath = try await imageSource.localImagePath(for: imageInfo, kind: artifactKind)
        let sourceFormat = try await detectFormat(of: sourcePath)

        let destinationDirectory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Fail fast with a clear message when the destination filesystem
        // can't hold the disk — otherwise the copy/convert dies mid-write
        // with an opaque I/O error. The source's on-disk size is the upper
        // bound of what gets written (conversion output is sparse-friendly).
        if let sourceSize = (try? FileManager.default.attributesOfItem(atPath: sourcePath))?[.size] as? Int64,
            let free = HostPreflight.freeDiskSpace(atPath: destinationDirectory),
            free < sourceSize
        {
            throw StorageBackendError.hostMisconfiguration(
                "not enough free disk space to materialize \(path): "
                    + "need \(HostPreflight.byteString(sourceSize)), "
                    + "have \(HostPreflight.byteString(free)). Free up space on the filesystem backing "
                    + "\(destinationDirectory).")
        }

        // Discard any partial output left by a previous crashed materialization.
        let stagingPath = path + ".partial"
        try? FileManager.default.removeItem(atPath: stagingPath)

        do {
            if sourceFormat == format.rawValue {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: stagingPath)
            } else {
                // Source and target formats differ — convert instead of copying,
                // so e.g. a qcow2 image really becomes a raw disk.
                let result = try await runQemuImg([
                    "convert",
                    "-f", sourceFormat,
                    "-O", format.rawValue,
                    sourcePath,
                    stagingPath,
                ])
                if result.terminationStatus != 0 {
                    let output = result.combinedOutput
                    logger.error(
                        "qemu-img convert failed",
                        metadata: [
                            "source": .string(sourcePath),
                            "target": .string(path),
                            "output": .string(output),
                        ])
                    throw qemuImgFailure(
                        output: output, context: "qemu-img convert", fallback: StorageBackendError.createFailed)
                }
            }

            // Atomic publish: rename within the same directory, so the disk
            // appears at its final path all-or-nothing.
            try FileManager.default.moveItem(atPath: stagingPath, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw error
        }

        logger.info(
            "Disk materialized from image",
            metadata: [
                "path": .string(path),
                "sourceImage": .string(sourcePath),
                "sourceFormat": .string(sourceFormat),
                "targetFormat": .string(format.rawValue),
            ])

        return DiskAttachment(path: path, format: format)
    }

    // MARK: - Volume Deletion

    public func deleteVolume(volumeId: String) async throws {
        let volumeDir = volumeDirectory(volumeId: volumeId)

        logger.info("Deleting volume", metadata: ["volumeId": .string(volumeId)])

        if FileManager.default.fileExists(atPath: volumeDir) {
            try FileManager.default.removeItem(atPath: volumeDir)
            logger.info("Volume deleted", metadata: ["volumeId": .string(volumeId)])
        } else {
            logger.warning(
                "Volume directory not found",
                metadata: [
                    "volumeId": .string(volumeId),
                    "path": .string(volumeDir),
                ])
        }
    }

    // MARK: - Volume Resize

    public func resizeVolume(volumePath: String, newSizeBytes: Int64) async throws {
        logger.info(
            "Resizing volume",
            metadata: [
                "path": .string(volumePath),
                "newSize": .stringConvertible(newSizeBytes),
            ])

        let result = try await runQemuImg(["resize", volumePath, "\(newSizeBytes)"])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img resize failed",
                metadata: [
                    "path": .string(volumePath),
                    "output": .string(output),
                ])
            throw qemuImgFailure(output: output, context: "qemu-img resize", fallback: StorageBackendError.resizeFailed)
        }

        logger.info(
            "Volume resized successfully",
            metadata: [
                "path": .string(volumePath),
                "newSize": .stringConvertible(newSizeBytes),
            ])
    }

    // MARK: - Snapshots

    /// Creates an external snapshot as a qcow2 overlay whose backing file is
    /// the volume. The backing format is detected rather than assumed, so raw
    /// volumes snapshot correctly too.
    public func createSnapshot(volumeId: String, snapshotId: String, volumePath: String) async throws -> String {
        let snapshotPath = snapshotPath(volumeId: volumeId, snapshotId: snapshotId)

        logger.info(
            "Creating snapshot",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "volumePath": .string(volumePath),
            ])

        let backingFormat = try await detectFormat(of: volumePath)

        try FileManager.default.createDirectory(
            atPath: (snapshotPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let result = try await runQemuImg([
            "create",
            "-f", "qcow2",
            "-b", volumePath,
            "-F", backingFormat,
            snapshotPath,
        ])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img snapshot create failed",
                metadata: [
                    "volumeId": .string(volumeId),
                    "output": .string(output),
                ])
            throw qemuImgFailure(
                output: output, context: "qemu-img create snapshot", fallback: StorageBackendError.snapshotFailed)
        }

        logger.info(
            "Snapshot created successfully",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "path": .string(snapshotPath),
            ])

        return snapshotPath
    }

    /// Deletes a snapshot. The path is derived from the IDs — the same
    /// derivation `createSnapshot` uses — rather than trusted from the wire,
    /// so deletion works even when the control plane never recorded the path
    /// (e.g. the create succeeded but its response was lost). A missing file
    /// is not an error: deletion is idempotent.
    public func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        let snapshotPath = snapshotPath(volumeId: volumeId, snapshotId: snapshotId)

        logger.info(
            "Deleting snapshot",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "path": .string(snapshotPath),
            ])

        if FileManager.default.fileExists(atPath: snapshotPath) {
            try FileManager.default.removeItem(atPath: snapshotPath)
            logger.info("Snapshot deleted", metadata: ["path": .string(snapshotPath)])
        } else {
            logger.warning("Snapshot not found", metadata: ["path": .string(snapshotPath)])
        }
    }

    // MARK: - Volume Clone

    /// Clones a volume into a new, fully independent volume of the same
    /// format. `qemu-img convert` produces a flattened copy, so the clone
    /// shares no backing chain with the source.
    public func cloneVolume(sourceVolumeId: String, sourcePath: String, targetVolumeId: String) async throws
        -> DiskAttachment
    {
        let sourceFormatString = try await detectFormat(of: sourcePath)
        guard let format = DiskFormat(rawValue: sourceFormatString) else {
            throw StorageBackendError.unsupportedFormat(sourceFormatString)
        }
        let targetPath = volumePath(volumeId: targetVolumeId, format: format)

        // Idempotent for the same reason `createVolume` is: a clone is how a
        // volume with a clone create-strategy comes into existence, and that
        // strategy is re-driven by every level-triggered sync until the volume
        // is observed present.
        if FileManager.default.fileExists(atPath: targetPath) {
            logger.debug("Clone target already exists", metadata: ["targetVolumeId": .string(targetVolumeId)])
            return DiskAttachment(path: targetPath, format: format)
        }

        logger.info(
            "Cloning volume",
            metadata: [
                "sourceVolumeId": .string(sourceVolumeId),
                "targetVolumeId": .string(targetVolumeId),
                "sourcePath": .string(sourcePath),
                "format": .string(format.rawValue),
            ])

        try FileManager.default.createDirectory(
            atPath: volumeDirectory(volumeId: targetVolumeId),
            withIntermediateDirectories: true,
            attributes: nil
        )

        try await publishAtomically(to: targetPath) { stagingPath in
            let result = try await self.runQemuImg([
                "convert",
                "-f", format.rawValue,
                "-O", format.rawValue,
                sourcePath,
                stagingPath,
            ])
            if result.terminationStatus != 0 {
                let output = result.combinedOutput
                self.logger.error(
                    "qemu-img clone failed",
                    metadata: [
                        "sourceVolumeId": .string(sourceVolumeId),
                        "output": .string(output),
                    ])
                throw self.qemuImgFailure(
                    output: output, context: "qemu-img clone", fallback: StorageBackendError.cloneFailed)
            }
        }

        logger.info(
            "Volume cloned successfully",
            metadata: [
                "sourceVolumeId": .string(sourceVolumeId),
                "targetVolumeId": .string(targetVolumeId),
                "targetPath": .string(targetPath),
            ])

        return DiskAttachment(path: targetPath, format: format)
    }

    // MARK: - Volume Info

    public func volumeInfo(volumePath: String) async throws -> VolumeInfoResult {
        logger.debug("Getting volume info", metadata: ["path": .string(volumePath)])

        let info = try await queryImageInfo(path: volumePath)

        return VolumeInfoResult(
            actualSize: info.actualSize,
            virtualSize: info.virtualSize,
            format: info.format,
            dirty: info.dirty ?? false,
            encrypted: info.encrypted ?? false
        )
    }

    /// Every complete volume in the store, keyed by the canonical uppercase
    /// form of its id (STR-148).
    ///
    /// "Complete" is doing real work here: the check is for the *published*
    /// `volume.<ext>` file, and every write path stages elsewhere and renames,
    /// so a directory left behind by a create that died mid-write reports as
    /// absent and the next sync re-drives it. Deliberately no `qemu-img info`
    /// — this runs on every sync, and one subprocess per volume per sync is
    /// not affordable on a dense host.
    public func listVolumes() async throws -> [String: DiskAttachment] {
        // "No store yet" and "a store I cannot read" are emphatically different
        // answers, and collapsing them into `[:]` was a data-loss bug: an empty
        // inventory is *authoritative* to both consumers — the reconciler plans
        // a create for every volume the sync wants, and the observed report's
        // full-list semantics confirm deletions that never happened. The store
        // is created lazily on first write, so its genuine absence is the
        // ordinary state of a fresh host and really is an empty inventory.
        // Anything else — EACCES, EIO on a network-backed store, EMFILE on a
        // dense host — is the agent being unable to answer, and it throws.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volumeStoragePath, isDirectory: &isDirectory) else {
            logger.debug(
                "Volume store does not exist yet; reporting no volumes",
                metadata: ["storagePath": .string(volumeStoragePath)])
            return [:]
        }
        guard isDirectory.boolValue else {
            throw StorageBackendError.hostMisconfiguration(
                "the volume store path \(volumeStoragePath) is a file, not a directory; "
                    + "point `volume_storage_dir` at a directory the agent can write.")
        }

        let entries: [String]
        do {
            entries = try enumerateVolumeStore(volumeStoragePath)
        } catch where Self.isFileNotFound(error) {
            // A child can vanish while Foundation builds the returned names.
            // The observed Darwin error wraps that ENOENT in
            // NSFileReadUnknownError (Cocoa 256), even though the store itself
            // remains readable. Retry the authoritative scan once after
            // teardown has finished removing the entry.
            logger.debug(
                "A volume entry disappeared during inventory; retrying the scan",
                metadata: [
                    "storagePath": .string(volumeStoragePath),
                    "error": .string(error.localizedDescription),
                ])
            do {
                entries = try enumerateVolumeStore(volumeStoragePath)
            } catch {
                throw unreadableVolumeStore(error)
            }
        } catch {
            throw unreadableVolumeStore(error)
        }

        var volumes: [String: DiskAttachment] = [:]
        for entry in entries {
            guard let volumeId = UUID(uuidString: entry)?.uuidString else { continue }
            for format in DiskFormat.allCases {
                let path = volumePath(volumeId: entry, format: format)
                if FileManager.default.fileExists(atPath: path) {
                    volumes[volumeId] = DiskAttachment(path: path, format: format)
                    break
                }
            }
        }
        return volumes
    }

    /// Foundation can wrap POSIX errors more than once. Only ENOENT means a
    /// child raced this scan; EACCES, EIO, EMFILE, and every unknown error are
    /// still failures of the store as a whole.
    private static func isFileNotFound(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSCocoaErrorDomain,
                candidate.code == NSFileNoSuchFileError || candidate.code == NSFileReadNoSuchFileError
            {
                return true
            }
            if candidate.domain == NSPOSIXErrorDomain,
                candidate.code == POSIXErrorCode.ENOENT.rawValue
            {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func unreadableVolumeStore(_ error: Error) -> StorageBackendError {
        logger.error(
            "Volume store exists but cannot be read; this host cannot account for its volumes",
            metadata: [
                "storagePath": .string(volumeStoragePath),
                "error": .string(error.localizedDescription),
            ])
        return .hostMisconfiguration(
            "cannot enumerate the volume store at \(volumeStoragePath): "
                + "\(error.localizedDescription). Ensure the agent user can read it.")
    }

    /// Runs `write` against a staging path and publishes its output to `path`
    /// with a rename inside the same directory, so the canonical path is
    /// all-or-nothing.
    ///
    /// This is what makes `listVolumes`' "the file is there" a sound answer to
    /// "does this volume exist?", which the reconciler's whole create/no-create
    /// decision rests on. Without it a truncated disk from an interrupted
    /// `qemu-img create` would read as a converged volume.
    private func publishAtomically(to path: String, _ write: (String) async throws -> Void) async throws {
        let stagingPath = path + ".partial"
        try? FileManager.default.removeItem(atPath: stagingPath)
        do {
            try await write(stagingPath)
            try FileManager.default.moveItem(atPath: stagingPath, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw error
        }
    }

    // MARK: - qemu-img Helpers

    private func runQemuImg(_ arguments: [String]) async throws -> ProcessResult {
        do {
            return try await runSubprocess(URL(fileURLWithPath: qemuImgPath), arguments)
        } catch let error as StorageBackendError {
            throw error
        } catch {
            // A spawn failure is a host problem (binary missing, not
            // executable), not an operation problem: classify it as permanent
            // with the fix, so the reconciler stops retrying and the operator
            // sees what to install.
            throw StorageBackendError.hostMisconfiguration(
                "failed to launch qemu-img at \(qemuImgPath): \(error.localizedDescription). "
                    + "If QEMU tools are not installed, install them "
                    + "(Debian/Ubuntu: `apt install qemu-utils`, macOS: `brew install qemu`).")
        }
    }

    /// Classifies a non-zero qemu-img exit: host-level causes (disk full,
    /// permissions) become permanent `hostMisconfiguration` errors with a
    /// remediation, everything else keeps its operation-specific error so
    /// existing handling is unchanged.
    private func qemuImgFailure(
        output: String, context: String, fallback: (String) -> StorageBackendError
    ) -> StorageBackendError {
        if output.contains("No space left on device") {
            return .hostMisconfiguration(
                "\(context) failed: no space left on device (storage path: \(volumeStoragePath)). "
                    + "Free up disk space or expand the volume storage filesystem. qemu-img output: \(output)")
        }
        if output.contains("Permission denied") {
            return .hostMisconfiguration(
                "\(context) failed: permission denied. Ensure the agent user can write the storage "
                    + "directories (default: \(volumeStoragePath)). qemu-img output: \(output)")
        }
        return fallback("\(context) failed: \(output)")
    }

    /// Detects an image's format string (e.g. "qcow2", "raw") via qemu-img info.
    private func detectFormat(of path: String) async throws -> String {
        try await queryImageInfo(path: path).format
    }

    /// Reads `qemu-img info` for an image that may be open elsewhere.
    ///
    /// `-U` (force-share) is what makes that possible: a running QEMU holds a
    /// write lock on every image it has opened, and without `-U` this call
    /// fails outright (STR-193). Resize is where that bit: both the size probe
    /// and the grow precheck inspect the volume, so a grow against an attached
    /// volume died here — reported as `Volume info query failed` — instead of
    /// reaching the guard that decides online vs offline. `detectFormat` runs
    /// the same query, so snapshot and clone would have failed identically had
    /// the control plane not refused those on an attached volume already.
    ///
    /// It belongs on this call and no other. `-U` is safe here precisely
    /// because inspection is read-only: the worst case is reading fields a
    /// concurrent writer is mid-update on. On a mutating invocation
    /// (`create`, `convert`, `resize`) the lock is doing real work — it is the
    /// only thing standing between us and rewriting qcow2 metadata underneath
    /// a live guest — so it must never be forced there.
    private func queryImageInfo(path: String) async throws -> QemuImgInfo {
        let result = try await runQemuImg(["info", "-U", "--output=json", path])
        if result.terminationStatus != 0 {
            throw StorageBackendError.infoFailed("qemu-img info failed: \(result.combinedOutput)")
        }
        return try JSONDecoder().decode(QemuImgInfo.self, from: result.standardOutput)
    }
}

// MARK: - Supporting Types

/// JSON structure from qemu-img info --output=json
private struct QemuImgInfo: Decodable {
    let filename: String
    let format: String
    let virtualSize: Int64
    let actualSize: Int64
    let dirty: Bool?
    let encrypted: Bool?
    let backingFilename: String?
    let backingFilenameFormat: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case format
        case virtualSize = "virtual-size"
        case actualSize = "actual-size"
        case dirty = "dirty-flag"
        case encrypted
        case backingFilename = "backing-filename"
        case backingFilenameFormat = "backing-filename-format"
    }
}
