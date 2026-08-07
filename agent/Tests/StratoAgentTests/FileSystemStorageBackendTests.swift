import Foundation
import Logging
import Testing
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

    func stub(subcommand: String, result: ProcessResult) {
        results[subcommand] = result
    }

    func record(executable: URL, arguments: [String]) -> ProcessResult {
        invocations.append(Invocation(executable: executable.path, arguments: arguments))
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

private func imageInfoJSON(format: String, virtualSize: Int64 = 1_073_741_824) -> ProcessResult {
    let json = """
        {"filename": "img", "format": "\(format)", "virtual-size": \(virtualSize), "actual-size": 313460}
        """
    return ProcessResult(terminationStatus: 0, standardOutput: Data(json.utf8), standardError: Data())
}

private struct StaticImageSource: ImageSource {
    let path: String
    func localImagePath(for imageInfo: ImageInfo) async throws -> String { path }
}

private func makeImageInfo() -> ImageInfo {
    ImageInfo(
        imageId: UUID(),
        projectId: UUID(),
        filename: "debian.qcow2",
        checksum: "abc",
        size: 1024,
        downloadURL: "http://localhost:8080/images/x"
    )
}

@Suite("FileSystemStorageBackend")
struct FileSystemStorageBackendTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "storage-backend-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBackend(
        root: String,
        recorder: SubprocessRecorder,
        imageSource: (any ImageSource)? = nil
    ) -> FileSystemStorageBackend {
        FileSystemStorageBackend(
            logger: Logger(label: "test"),
            volumeStoragePath: root,
            qemuImgPath: "/fake/qemu-img",
            imageSource: imageSource,
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

        #expect(attachment == DiskAttachment(path: "\(root)/vol-1/volume.qcow2", format: .qcow2))
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

        #expect(attachment.path == "\(root)/vol-2/volume.raw")
        #expect(attachment.format == .raw)
        let invocations = await recorder.invocations
        #expect(invocations[0].arguments.contains("raw"))
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

    @Test func qemuImgDiskFullIsClassifiedAsPermanentHostProblem() async throws {
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
            #expect(error.failureClassification == .permanent)
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

        #expect(attachment == DiskAttachment(path: target, format: .qcow2))
        // Same format: plain copy, no qemu-img convert.
        let subcommands = await recorder.invocations.map { $0.arguments.first }
        #expect(!subcommands.contains("convert"))
        #expect(FileManager.default.contents(atPath: target) == Data("image-bytes".utf8))
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

        #expect(attachment.format == .raw)
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

        #expect(attachment.path == target)
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

        #expect(attachment.path == target)
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
            volumeId: "vol-9", imageInfo: makeImageInfo(), format: .qcow2)

        #expect(attachment == DiskAttachment(path: "\(root)/vol-9/volume.qcow2", format: .qcow2))
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

        #expect(attachment == DiskAttachment(path: "\(root)/vol-2/volume.qcow2", format: .qcow2))
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
        #expect(listed[published]?.format == .qcow2)
        #expect(listed[published]?.path == "\(root)/\(published)/volume.qcow2")
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
        #expect(create?.arguments == ["create", "-f", "qcow2", "-b", volumePath, "-F", "raw", snapshotPath])
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
