import Foundation
import Logging
import Testing
import StratoAgentTestSupport
import StratoShared

@testable import StratoAgentCore

/// Records qemu-img invocations and replays scripted results, so the backend's
/// full decision logic (path layout, copy vs convert, argument construction)
/// is exercised without qemu-img installed.
private actor SubprocessRecorder {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    /// Results keyed by the qemu-img subcommand (first argument); unknown
    /// subcommands succeed with empty output.
    private var results: [String: ProcessResult] = [:]
    /// When set, an `info` that does not force-share fails the way qemu-img
    /// does against an image a running QEMU holds open (STR-193).
    ///
    /// Scoped to `info` on purpose, matching qemu-img 10.1: `create -b` opens
    /// the backing file read-only and takes no conflicting lock, so a snapshot
    /// overlay over a live volume needs no `-U` of its own — only the format
    /// detection ahead of it does.
    private var imageIsHeldByAnotherProcess = false

    func stub(subcommand: String, result: ProcessResult) {
        results[subcommand] = result
    }

    /// Simulates a live hypervisor holding the image's write lock.
    func holdImageLock() {
        imageIsHeldByAnotherProcess = true
    }

    func record(executable: URL, arguments: [String]) -> ProcessResult {
        invocations.append(Invocation(executable: executable.path, arguments: arguments))
        if imageIsHeldByAnotherProcess, arguments.first == "info", !arguments.contains("-U") {
            return ProcessResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data(
                    """
                    qemu-img: Could not open 'volume.qcow2': Failed to get shared "write" lock
                    Is another process using the image [volume.qcow2]?
                    """.utf8))
        }
        let result =
            results[arguments.first ?? ""]
            ?? ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
        // Mirror qemu-img's side effect: a successful `convert` or `create`
        // produces its output file, which the backend then publishes with an
        // atomic rename.
        //
        // Locating that file needs care. `qemu-img create` puts it last for a
        // snapshot overlay (`create -f qcow2 -b <base> -F <fmt> <out>`) but
        // second-to-last for a sized volume (`create -f raw <out> <bytes>`), so
        // the size argument is what discriminates. Reading the wrong slot wrote
        // a file named after the *backing format* into the test's working
        // directory — which is how `agent/raw` got committed.
        if result.terminationStatus == 0, let subcommand = arguments.first,
            subcommand == "convert" || subcommand == "create"
        {
            let output: String? =
                (subcommand == "create" && Int64(arguments.last ?? "") != nil)
                ? (arguments.count >= 2 ? arguments[arguments.count - 2] : nil)
                : arguments.last
            if let output {
                FileManager.default.createFile(
                    atPath: output, contents: Data("\(subcommand)d-bytes".utf8))
            }
        }
        return result
    }
}

private func imageInfoJSON(
    format: String,
    virtualSize: Int64 = 1_073_741_824,
    actualSize: Int64 = 313_460
) -> ProcessResult {
    let json = """
        {"filename": "img", "format": "\(format)", "virtual-size": \(virtualSize), "actual-size": \(actualSize)}
        """
    return ProcessResult(terminationStatus: 0, standardOutput: Data(json.utf8), standardError: Data())
}

private struct StaticImageSource: ImageSource {
    let path: String
    func localImagePath(for imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String { path }
}

/// Deterministically models the observed Foundation boundary: read the real
/// entries, remove one from another task, then emit the observed Cocoa wrapper
/// instead of relying on scheduler timing to make the native call fail.
private final class DisappearingVolumeEnumerator: Sendable {
    private let disappearingDirectory: String

    init(disappearingDirectory: String) {
        self.disappearingDirectory = disappearingDirectory
    }

    func contents(atPath path: String) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: path)
        guard FileManager.default.fileExists(atPath: disappearingDirectory) else { return entries }

        let removed = DispatchSemaphore(value: 0)
        Task.detached { [disappearingDirectory] in
            try? FileManager.default.removeItem(atPath: disappearingDirectory)
            removed.signal()
        }
        removed.wait()
        precondition(!FileManager.default.fileExists(atPath: disappearingDirectory))

        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
    }
}

/// A wrapped I/O failure has the same Cocoa surface as the disappearing-entry
/// race, but its underlying cause is store-level and must remain fatal.
private struct FailingVolumeEnumerator: Sendable {
    func contents(atPath path: String) throws -> [String] {
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EIO)])
    }
}

private func makeImageInfo() -> ImageInfo {
    ImageInfo(
        imageId: UUID(),
        projectId: UUID(),
        architecture: .x86_64,
        artifacts: [
            ArtifactInfo(
                kind: .diskImage, filename: "debian.qcow2",
                checksum: String(repeating: "a", count: 64), size: 1024,
                downloadURL: "http://localhost:8080/images/x?artifact=disk-image")
        ]
    )
}

@Suite("FileSystemStorageBackend")
struct FileSystemStorageBackendTests {
    private func makeBackend(
        root: String,
        recorder: SubprocessRecorder,
        imageSource: (any ImageSource)? = nil,
        enumerateVolumeStore: @escaping @Sendable (String) throws -> [String] = {
            try FileManager.default.contentsOfDirectory(atPath: $0)
        },
        copyItem: @escaping @Sendable (String, String) throws -> Void = {
            try FileManager.default.copyItem(atPath: $0, toPath: $1)
        },
        freeDiskSpace: @escaping @Sendable (String) -> Int64? = { _ in Int64.max },
        publishItem: @escaping @Sendable (String, String) throws -> Void = {
            try DurableFileWriter().publish(stagingPath: $0, to: $1)
        }
    ) -> FileSystemStorageBackend {
        FileSystemStorageBackend(
            logger: Logger(label: "test"),
            volumeStoragePath: root,
            qemuImgPath: "/fake/qemu-img",
            imageSource: imageSource,
            enumerateVolumeStore: enumerateVolumeStore,
            copyItem: copyItem,
            freeDiskSpace: freeDiskSpace,
            publishItem: publishItem,
            runSubprocess: { executable, arguments in
                await recorder.record(executable: executable, arguments: arguments)
            }
        )
    }

    @Test func createVolumeUsesCanonicalLayoutAndCreateArgs() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        let attachment = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)

        #expect(attachment == .file(path: "\(root)/vol-1/volume.qcow2", format: .qcow2))
        let invocations = await recorder.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].executable == "/fake/qemu-img")
        // Written to a staging path and published with a rename, so the
        // canonical path only ever holds a finished volume (STR-148).
        #expect(
            invocations[0].arguments == ["create", "-f", "qcow2", "\(root)/vol-1/volume.qcow2.partial", "42"])
        #expect(FileManager.default.fileExists(atPath: "\(root)/vol-1/volume.qcow2"))
        #expect(FileManager.default.fileExists(atPath: "\(root)/vol-1/volume.qcow2.partial") == false)
        // The backend owns the layout: the volume directory must exist.
        #expect(FileManager.default.fileExists(atPath: "\(root)/vol-1"))
    }

    @Test func createVolumeRawFormatDrivesLayoutAndArgs() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        let attachment = try await backend.createVolume(volumeId: "vol-2", sizeBytes: 7, format: .raw)

        #expect(attachment.filePath == "\(root)/vol-2/volume.raw")
        #expect(attachment.fileFormat == .raw)
        let invocations = await recorder.invocations
        #expect(invocations[0].arguments.contains("raw"))
    }

    @Test func adoptsHistoricalDiskByIdentityAndDeletesBothLinks() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let legacyPath = "\(root)/legacy-vm-disk.qcow2"
        let bytes = Data("guest-changed-bytes".utf8)
        FileManager.default.createFile(atPath: legacyPath, contents: bytes)
        let volumeId = UUID().uuidString
        let backend = makeBackend(root: root, recorder: SubprocessRecorder())

        let adopted = try await backend.adoptVolume(
            volumeId: volumeId, existingPath: legacyPath, format: .qcow2)

        #expect(adopted.filePath == "\(root)/\(volumeId)/volume.qcow2")
        #expect(FileManager.default.contents(atPath: adopted.filePath) == bytes)
        #expect(FileManager.default.contents(atPath: legacyPath) == bytes)
        #expect(try await backend.listVolumes()[volumeId] == adopted)

        try await backend.deleteVolume(volumeId: volumeId)
        #expect(!FileManager.default.fileExists(atPath: adopted.filePath))
        #expect(!FileManager.default.fileExists(atPath: legacyPath))
    }

    @Test func createVolumeSurfacesQemuImgFailure() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(
            subcommand: "create",
            result: ProcessResult(
                terminationStatus: 1, standardOutput: Data(), standardError: Data("disk full".utf8)))
        let backend = makeBackend(root: root, recorder: recorder)

        await #expect(throws: StorageBackendError.self) {
            _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)
        }
    }

    @Test func qemuImgDiskFullIsClassifiedAsBlockedSpaceExhaustion() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(
            subcommand: "create",
            result: ProcessResult(
                terminationStatus: 1, standardOutput: Data(),
                standardError: Data("qemu-img: vol: No space left on device".utf8)))
        let backend = makeBackend(root: root, recorder: recorder)

        do {
            _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)
            Issue.record("expected createVolume to throw")
        } catch let error as StorageBackendError {
            #expect(error.failureClassification == .blocked)
            guard case .insufficientDiskSpace = error else {
                Issue.record("expected insufficientDiskSpace, got \(error)")
                return
            }
            let description = error.localizedDescription
            #expect(description.contains("no space left on device"))
        }
    }

    @Test func qemuImgSpawnFailureIsClassifiedWithInstallHint() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        struct SpawnError: Error {}
        let backend = FileSystemStorageBackend(
            logger: Logger(label: "test"),
            volumeStoragePath: root,
            qemuImgPath: "/nonexistent/qemu-img",
            imageSource: nil,
            runSubprocess: { _, _ in throw SpawnError() }
        )

        do {
            _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)
            Issue.record("expected createVolume to throw")
        } catch let error as StorageBackendError {
            #expect(error.failureClassification == .permanent)
            guard case .hostMisconfiguration(let reason) = error else {
                Issue.record("expected hostMisconfiguration, got \(error)")
                return
            }
            #expect(reason.contains("qemu-utils"))
            #expect(reason.contains("/nonexistent/qemu-img"))
        }
    }

    @Test func materializeDiskCopiesWhenFormatsMatch() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        let target = "\(root)/vms/vm-1/disk.qcow2"
        let attachment = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .qcow2)

        #expect(attachment == .file(path: target, format: .qcow2))
        // Same format: plain copy, no qemu-img convert.
        let subcommands = await recorder.invocations.map { $0.arguments.first }
        #expect(!subcommands.contains("convert"))
        #expect(FileManager.default.contents(atPath: target) == Data("image-bytes".utf8))
    }

    @Test func materializeDiskCopyENOSPCIsBlocked() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath),
            copyItem: { _, _ in throw POSIXError(.ENOSPC) })
        let target = "\(root)/vms/vm-full/disk.qcow2"

        do {
            _ = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .qcow2)
            Issue.record("expected insufficientDiskSpace")
        } catch let error as StorageBackendError {
            guard case .insufficientDiskSpace = error else {
                Issue.record("expected insufficientDiskSpace, got \(error)")
                return
            }
            #expect(error.failureClassification == .blocked)
        } catch {
            Issue.record("expected insufficientDiskSpace, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(!FileManager.default.fileExists(atPath: target + ".partial"))
    }

    @Test func materializeDiskPublishENOSPCIsBlocked() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath),
            publishItem: { stagingPath, _ in
                throw DurableFileWriteError(
                    operation: "synchronize", path: stagingPath, errorNumber: ENOSPC)
            })
        let target = "\(root)/vms/vm-publish-full/disk.qcow2"

        do {
            _ = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .qcow2)
            Issue.record("expected insufficientDiskSpace")
        } catch let error as StorageBackendError {
            guard case .insufficientDiskSpace = error else {
                Issue.record("expected insufficientDiskSpace, got \(error)")
                return
            }
            #expect(error.failureClassification == .blocked)
        } catch {
            Issue.record("expected insufficientDiskSpace, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(!FileManager.default.fileExists(atPath: target + ".partial"))
    }

    @Test func materializeDiskCopiesReadOnlySource() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(
            atPath: sourcePath, contents: Data("read-only-image".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: sourcePath)

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        let target = "\(root)/vms/vm-read-only/disk.qcow2"
        let attachment = try await backend.materializeDisk(
            at: target, from: makeImageInfo(), format: .qcow2)

        #expect(attachment.filePath == target)
        #expect(FileManager.default.contents(atPath: target) == Data("read-only-image".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o444)
    }

    @Test func materializeDiskConvertsWhenFormatsDiffer() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        let target = "\(root)/vms/vm-1/rootfs.raw"
        let attachment = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .raw)

        #expect(attachment.fileFormat == .raw)
        // The conversion writes to a staging path, then publishes via rename.
        let convert = await recorder.invocations.first { $0.arguments.first == "convert" }
        #expect(convert?.arguments == ["convert", "-f", "qcow2", "-O", "raw", sourcePath, "\(target).partial"])
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(!FileManager.default.fileExists(atPath: "\(target).partial"))
    }

    @Test func materializeDiskFailedConversionLeavesNoDisk() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        await recorder.stub(
            subcommand: "convert",
            result: ProcessResult(
                terminationStatus: 1, standardOutput: Data(), standardError: Data("no space".utf8)))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        let target = "\(root)/vms/vm-1/rootfs.raw"
        await #expect(throws: StorageBackendError.self) {
            _ = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .raw)
        }
        // Nothing published, nothing staged — a retry starts clean instead of
        // mistaking a partial artifact for a materialized disk.
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(!FileManager.default.fileExists(atPath: "\(target).partial"))
    }

    @Test func materializeDiskDiscardsStalePartialFromCrashedRun() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        // Simulate a previous materialization that died mid-copy.
        let target = "\(root)/vms/vm-1/disk.qcow2"
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(target).partial", contents: Data("truncated".utf8))

        let attachment = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .qcow2)

        #expect(attachment.filePath == target)
        #expect(FileManager.default.contents(atPath: target) == Data("image-bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: "\(target).partial"))
    }

    @Test func materializeDiskIsIdempotent() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = "\(root)/vms/vm-1/disk.qcow2"
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target, contents: Data("existing".utf8))

        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)  // no image source needed

        let attachment = try await backend.materializeDisk(at: target, from: makeImageInfo(), format: .qcow2)

        #expect(attachment.filePath == target)
        #expect(await recorder.invocations.isEmpty)
        #expect(FileManager.default.contents(atPath: target) == Data("existing".utf8))
    }

    @Test func materializeDiskWithoutImageSourceThrows() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = makeBackend(root: root, recorder: SubprocessRecorder())

        await #expect(throws: StorageBackendError.self) {
            _ = try await backend.materializeDisk(
                at: "\(root)/vms/vm-1/disk.qcow2", from: makeImageInfo(), format: .qcow2)
        }
    }

    @Test func createVolumeFromImagePlacesDiskInVolumeLayout() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourcePath = "\(root)/cached-image.qcow2"
        FileManager.default.createFile(atPath: sourcePath, contents: Data("image-bytes".utf8))

        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: sourcePath))

        let attachment = try await backend.createVolumeFromImage(
            volumeId: "vol-9", imageInfo: makeImageInfo(), format: .qcow2,
            artifactKind: .diskImage)

        #expect(attachment == .file(path: "\(root)/vol-9/volume.qcow2", format: .qcow2))
        #expect(FileManager.default.fileExists(atPath: "\(root)/vol-9/volume.qcow2"))
    }

    @Test func cloneVolumeDerivesTargetPathAndConverts() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(root: root, recorder: recorder)

        let sourcePath = "\(root)/vol-1/volume.qcow2"
        let attachment = try await backend.cloneVolume(
            sourceVolumeId: "vol-1", sourcePath: sourcePath, targetVolumeId: "vol-2")

        #expect(attachment == .file(path: "\(root)/vol-2/volume.qcow2", format: .qcow2))
        let convert = await recorder.invocations.first { $0.arguments.first == "convert" }
        // Staged and renamed, like `createVolume`: a clone's target path is
        // also a presence signal the reconciler reads (STR-148).
        #expect(
            convert?.arguments == [
                "convert", "-f", "qcow2", "-O", "qcow2", sourcePath,
                "\(root)/vol-2/volume.qcow2.partial",
            ])
        #expect(FileManager.default.fileExists(atPath: "\(root)/vol-2/volume.qcow2"))
    }

    @Test func cloneRefusesBeforeWritingWhenSourceFootprintExceedsFreeSpace() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let backend = makeBackend(
            root: root,
            recorder: recorder,
            freeDiskSpace: { _ in 313_459 })

        await #expect(throws: StorageBackendError.self) {
            try await backend.cloneVolume(
                sourceVolumeId: "source",
                sourcePath: "\(root)/source/volume.qcow2",
                targetVolumeId: "target")
        }

        let invocations = await recorder.invocations
        #expect(invocations.filter { $0.arguments.first == "convert" }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(root)/target"))
        #expect(!FileManager.default.fileExists(atPath: "\(root)/target/volume.qcow2.partial"))
    }

    /// The invariant `listVolumes` rests on: presence means *complete*. A
    /// directory a crashed create left behind is not a volume, so the next sync
    /// re-drives it rather than reading a truncated disk as converged.
    @Test func listVolumesReportsOnlyPublishedVolumes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        let published = UUID().uuidString
        let halfWritten = UUID().uuidString
        _ = try await backend.createVolume(volumeId: published, sizeBytes: 42, format: .qcow2)
        try FileManager.default.createDirectory(
            atPath: "\(root)/\(halfWritten)", withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: "\(root)/\(halfWritten)/volume.qcow2.partial", contents: Data("torn".utf8))
        // A non-UUID directory cannot be named on the wire, so it can never be
        // reconciled and is not reported.
        try FileManager.default.createDirectory(
            atPath: "\(root)/not-a-uuid", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(root)/not-a-uuid/volume.qcow2", contents: Data())

        let listed = try await backend.listVolumes()
        #expect(Set(listed.keys) == [published])
        #expect(listed[published]?.fileFormat == .qcow2)
        #expect(listed[published]?.filePath == "\(root)/\(published)/volume.qcow2")
    }

    /// STR-251: model teardown outside the backend actor removing a directory
    /// after it was enumerated. The observed ENOENT is wrapped as Cocoa 256;
    /// that child race must not turn the whole store into a host failure or
    /// prevent the create immediately following cleanup.
    @Test func teardownAndCreateSurviveAnEntryDisappearingDuringInventory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let removedId = UUID().uuidString
        let removedDirectory = "\(root)/\(removedId)"
        try FileManager.default.createDirectory(atPath: removedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: "\(removedDirectory)/volume.qcow2", contents: Data("old".utf8))

        let enumerator = DisappearingVolumeEnumerator(disappearingDirectory: removedDirectory)
        let backend = makeBackend(
            root: root,
            recorder: SubprocessRecorder(),
            enumerateVolumeStore: { try enumerator.contents(atPath: $0) })

        #expect(try await backend.listVolumes().isEmpty)

        let createdId = UUID().uuidString
        _ = try await backend.createVolume(volumeId: createdId, sizeBytes: 42, format: .qcow2)
        let listed = try await backend.listVolumes()
        #expect(Set(listed.keys) == [createdId])
    }

    /// A store that does not exist yet is genuinely empty — every host is in
    /// that state before its first volume.
    @Test func listVolumesTreatsAnAbsentStoreAsEmpty() async throws {
        let root = try makeTempDir()
        try FileManager.default.removeItem(atPath: root)
        let backend = makeBackend(root: root, recorder: SubprocessRecorder())

        #expect(try await backend.listVolumes().isEmpty)
    }

    /// A store that exists but cannot be *used* is not an empty store, and
    /// saying it is would be a data-loss bug: an empty inventory is
    /// authoritative to both consumers, so the reconciler would plan a create
    /// for every volume the control plane wants here and the observed report
    /// would confirm deletions that never happened.
    ///
    /// Provoked with a path that is a file rather than a directory. The other
    /// route into the same guard — a directory the agent user cannot read —
    /// is not testable everywhere, since a process holding `CAP_DAC_OVERRIDE`
    /// (which this project's containers do) is never denied one; this branch
    /// is deterministic and exercises the same refusal.
    @Test func listVolumesThrowsWhenTheStoreIsNotUsable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let storePath = "\(root)/store"
        FileManager.default.createFile(atPath: storePath, contents: Data("not a directory".utf8))
        let backend = makeBackend(root: storePath, recorder: SubprocessRecorder())

        await #expect(throws: StorageBackendError.self) {
            try await backend.listVolumes()
        }
    }

    @Test func listVolumesStillThrowsForAGenuineIOFailure() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let enumerator = FailingVolumeEnumerator()
        let backend = makeBackend(
            root: root, recorder: SubprocessRecorder(),
            enumerateVolumeStore: { try enumerator.contents(atPath: $0) })

        await #expect(throws: StorageBackendError.self) {
            try await backend.listVolumes()
        }
    }

    /// Create is idempotent at the "already satisfied" level, which the
    /// actuator contract requires: a level-triggered sync may re-drive a create
    /// whose success report was lost.
    @Test func createVolumeIsIdempotent() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)
        _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)

        let creates = await recorder.invocations.filter { $0.arguments.first == "create" }
        #expect(creates.count == 1)
    }

    @Test func snapshotUsesDetectedBackingFormat() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "raw"))
        let backend = makeBackend(root: root, recorder: recorder)

        let volumePath = "\(root)/vol-1/volume.raw"
        let snapshotPath = try await backend.createSnapshot(
            volumeId: "vol-1", snapshotId: "snap-1", volumePath: volumePath)

        #expect(snapshotPath == "\(root)/vol-1/snapshots/snap-1.qcow2")
        let create = await recorder.invocations.first { $0.arguments.first == "create" }
        // Overlay is qcow2, but the backing format is detected, not assumed.
        #expect(
            create?.arguments
                == ["create", "-f", "qcow2", "-b", volumePath, "-F", "raw", snapshotPath + ".partial"])
        #expect(FileManager.default.contents(atPath: snapshotPath) == Data("created-bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: snapshotPath + ".partial"))
    }

    @Test func snapshotDoesNotRequireParentFootprintToBeFree() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let gibibyte: Int64 = 1_073_741_824
        await recorder.stub(
            subcommand: "info",
            result: imageInfoJSON(
                format: "qcow2",
                virtualSize: 100 * gibibyte,
                actualSize: 70 * gibibyte))
        let backend = makeBackend(
            root: root,
            recorder: recorder,
            freeDiskSpace: { _ in 30 * gibibyte })

        let snapshotPath = try await backend.createSnapshot(
            volumeId: "vol-1",
            snapshotId: "snap-1",
            volumePath: "\(root)/vol-1/volume.qcow2")

        #expect(snapshotPath == "\(root)/vol-1/snapshots/snap-1.qcow2")
        let create = try #require(await recorder.invocations.first { $0.arguments.first == "create" })
        #expect(create.arguments.last == snapshotPath + ".partial")
        #expect(FileManager.default.fileExists(atPath: snapshotPath))
        #expect(!FileManager.default.fileExists(atPath: snapshotPath + ".partial"))
    }

    @Test func createSnapshotIsIdempotent() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "raw"))
        let backend = makeBackend(root: root, recorder: recorder)
        let volumePath = "\(root)/vol-1/volume.raw"

        let snapshotPath = try await backend.createSnapshot(
            volumeId: "vol-1", snapshotId: "snap-1", volumePath: volumePath)
        let originalPointInTime = Data("original-point-in-time".utf8)
        try originalPointInTime.write(to: URL(fileURLWithPath: snapshotPath))

        let retriedPath = try await backend.createSnapshot(
            volumeId: "vol-1", snapshotId: "snap-1", volumePath: volumePath)

        #expect(retriedPath == snapshotPath)
        #expect(FileManager.default.contents(atPath: snapshotPath) == originalPointInTime)
        let invocations = await recorder.invocations
        #expect(invocations.filter { $0.arguments.first == "info" }.count == 1)
        #expect(invocations.filter { $0.arguments.first == "create" }.count == 1)
    }

    @Test func deleteSnapshotIsIdempotent() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = makeBackend(root: root, recorder: SubprocessRecorder())

        // No snapshot file exists — must not throw.
        try await backend.deleteSnapshot(volumeId: "vol-1", snapshotId: "snap-1")
    }

    @Test func deleteVolumeRemovesDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/vol-1", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(root)/vol-1/volume.qcow2", contents: Data())
        let backend = makeBackend(root: root, recorder: SubprocessRecorder())

        try await backend.deleteVolume(volumeId: "vol-1")

        #expect(!FileManager.default.fileExists(atPath: "\(root)/vol-1"))
        // Idempotent: deleting again must not throw.
        try await backend.deleteVolume(volumeId: "vol-1")
    }

    @Test func resizeVolumePassesNewSize() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        try await backend.resizeVolume(volumePath: "\(root)/vol-1/volume.qcow2", newSizeBytes: 99)

        let invocations = await recorder.invocations
        #expect(invocations[0].arguments == ["resize", "\(root)/vol-1/volume.qcow2", "99"])
    }

    @Test func volumeInfoParsesQemuImgJSON() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2", virtualSize: 555))
        let backend = makeBackend(root: root, recorder: recorder)

        let info = try await backend.volumeInfo(volumePath: "\(root)/vol-1/volume.qcow2")

        #expect(info.format == "qcow2")
        #expect(info.virtualSize == 555)
        #expect(!info.dirty)
    }

    /// A running QEMU holds a write lock on every image it has open, so an
    /// unqualified `qemu-img info` against an attached volume fails outright.
    /// Inspection is read-only, so it force-shares (STR-193).
    @Test func volumeInfoReadsAnImageAnotherProcessHoldsOpen() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2", virtualSize: 555))
        await recorder.holdImageLock()
        let backend = makeBackend(root: root, recorder: recorder)

        let info = try await backend.volumeInfo(volumePath: "\(root)/vol-1/volume.qcow2")

        #expect(info.virtualSize == 555)
        let query = try #require(await recorder.invocations.first { $0.arguments.first == "info" })
        #expect(query.arguments == ["info", "-U", "--output=json", "\(root)/vol-1/volume.qcow2"])
    }

    /// `detectFormat` runs the same query, so the lock reached every caller of
    /// the shared inspection helper, not just volume info. The overlay's own
    /// `create -b` needs no `-U` — it opens the backing file read-only
    /// (STR-193).
    @Test func snapshotDetectsBackingFormatOfAnImageAnotherProcessHoldsOpen() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "raw"))
        await recorder.holdImageLock()
        let backend = makeBackend(root: root, recorder: recorder)

        let volumePath = "\(root)/vol-1/volume.raw"
        let snapshotPath = try await backend.createSnapshot(
            volumeId: "vol-1", snapshotId: "snap-1", volumePath: volumePath)

        #expect(snapshotPath == "\(root)/vol-1/snapshots/snap-1.qcow2")
        let create = try #require(await recorder.invocations.first { $0.arguments.first == "create" })
        #expect(
            create.arguments
                == ["create", "-f", "qcow2", "-b", volumePath, "-F", "raw", snapshotPath + ".partial"])
    }

    /// Force-share belongs on inspection alone. On a mutating invocation the
    /// lock is the only thing between the agent and rewriting qcow2 metadata
    /// underneath a live guest, so it must never be forced there (STR-193).
    @Test func mutatingInvocationsNeverForceShare() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = SubprocessRecorder()
        await recorder.stub(subcommand: "info", result: imageInfoJSON(format: "qcow2"))
        let source = "\(root)/source.qcow2"
        FileManager.default.createFile(atPath: source, contents: Data("image".utf8))
        let backend = makeBackend(
            root: root, recorder: recorder, imageSource: StaticImageSource(path: source))

        _ = try await backend.createVolume(volumeId: "vol-1", sizeBytes: 42, format: .qcow2)
        _ = try await backend.createVolumeFromImage(
            volumeId: "vol-2", imageInfo: makeImageInfo(), format: .raw,
            artifactKind: .diskImage)
        _ = try await backend.cloneVolume(
            sourceVolumeId: "vol-1", sourcePath: "\(root)/vol-1/volume.qcow2", targetVolumeId: "vol-3")
        _ = try await backend.createSnapshot(
            volumeId: "vol-1", snapshotId: "snap-1", volumePath: "\(root)/vol-1/volume.qcow2")
        try await backend.resizeVolume(volumePath: "\(root)/vol-1/volume.qcow2", newSizeBytes: 99)

        let mutating = await recorder.invocations.filter { $0.arguments.first != "info" }
        #expect(!mutating.isEmpty)
        #expect(mutating.allSatisfy { !$0.arguments.contains("-U") })
    }
}

@Suite("DiskFormat")
struct DiskFormatTests {
    @Test func inferredFromPathExtension() {
        #expect(DiskFormat(volumePath: "/x/vol-1/volume.qcow2") == .qcow2)
        #expect(DiskFormat(volumePath: "/x/vm-1/rootfs.raw") == .raw)
        // Unknown extensions fall back to the historical qcow2 assumption.
        #expect(DiskFormat(volumePath: "/x/vm-1/rootfs.ext4") == .qcow2)
        #expect(DiskFormat(volumePath: "/x/vm-1/disk") == .qcow2)
    }
}
