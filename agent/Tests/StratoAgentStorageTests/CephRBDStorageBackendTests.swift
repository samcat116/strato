import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

private actor CephCommandRecorder {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var images: Set<String> = []
    private var snapshots: Set<String> = []
    private var imageMetadata: [String: [String: String]] = [:]
    private let sourceFormat: String
    private let allImagesExist: Bool
    private let features: [String]
    var createFailureEcho: String?
    var failNextSnapshotCreateAfterMutation = false
    var failNextImportAfterMutation = false
    var failNextFlatten = false
    var failNextSecretUndefine = false

    init(
        sourceFormat: String = "raw", allImagesExist: Bool = false,
        features: [String] = ["layering", "exclusive-lock"]
    ) {
        self.sourceFormat = sourceFormat
        self.allImagesExist = allImagesExist
        self.features = features
    }

    func run(_ executable: URL, _ arguments: [String]) -> ProcessResult {
        invocations.append(Invocation(executable: executable.path, arguments: arguments))
        if executable.lastPathComponent == "qemu-img", arguments.first == "info" {
            return success("{\"format\":\"\(sourceFormat)\"}")
        }
        if executable.lastPathComponent == "virsh" {
            if arguments.first == "secret-undefine", failNextSecretUndefine {
                failNextSecretUndefine = false
                return failure("libvirt refused secret cleanup")
            }
            return success()
        }

        if let metadataIndex = arguments.firstIndex(of: "image-meta"),
            arguments.index(after: metadataIndex) < arguments.endIndex
        {
            let operation = arguments[arguments.index(after: metadataIndex)]
            guard metadataIndex.advanced(by: 3) < arguments.endIndex else {
                return failure("missing image metadata arguments")
            }
            let image = arguments[metadataIndex.advanced(by: 2)]
            let key = arguments[metadataIndex.advanced(by: 3)]
            switch operation {
            case "get":
                guard let value = imageMetadata[image]?[key] else {
                    return failure("metadata not found")
                }
                return success(value + "\n")
            case "set":
                guard metadataIndex.advanced(by: 4) < arguments.endIndex else {
                    return failure("missing image metadata value")
                }
                imageMetadata[image, default: [:]][key] =
                    arguments[metadataIndex.advanced(by: 4)]
                return success()
            default:
                return failure("unsupported image metadata operation")
            }
        }

        if let snapIndex = arguments.firstIndex(of: "snap"),
            arguments.index(after: snapIndex) < arguments.endIndex
        {
            let operation = arguments[arguments.index(after: snapIndex)]
            switch operation {
            case "ls":
                guard snapIndex.advanced(by: 2) < arguments.endIndex else {
                    return failure("missing image")
                }
                let image = arguments[snapIndex.advanced(by: 2)]
                let names = snapshots.compactMap { coordinate -> String? in
                    let prefix = image + "@"
                    guard coordinate.hasPrefix(prefix) else { return nil }
                    return String(coordinate.dropFirst(prefix.count))
                }.sorted()
                let payload = names.map { ["name": $0] }
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
                return ProcessResult(
                    terminationStatus: 0, standardOutput: data, standardError: Data())
            case "create":
                guard let coordinate = value(after: "create", in: arguments) else {
                    return failure("missing snapshot")
                }
                snapshots.insert(coordinate)
                if failNextSnapshotCreateAfterMutation {
                    failNextSnapshotCreateAfterMutation = false
                    return failure("snapshot already exists")
                }
                return success()
            case "rm":
                if let coordinate = value(after: "rm", in: arguments) {
                    snapshots.remove(coordinate)
                }
                return success()
            case "purge":
                guard let image = value(after: "purge", in: arguments) else {
                    return failure("missing image")
                }
                snapshots = snapshots.filter { !$0.hasPrefix(image + "@") }
                return success()
            default:
                return success()
            }
        }
        if arguments.contains("info"), let coordinate = arguments.last {
            if allImagesExist || images.contains(coordinate) {
                let payload: [String: Any] = [
                    "size": 2_097_152,
                    "format": 2,
                    "features": features,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                return ProcessResult(
                    terminationStatus: 0, standardOutput: data, standardError: Data())
            }
            return failure("rbd: error opening image: No such file or directory")
        }
        if arguments.contains("create"), let coordinate = value(after: "create", in: arguments) {
            if let createFailureEcho { return failure(createFailureEcho) }
            images.insert(coordinate)
            return success()
        }
        if let cloneIndex = arguments.firstIndex(of: "clone"),
            cloneIndex.advanced(by: 2) < arguments.endIndex
        {
            images.insert(arguments[cloneIndex.advanced(by: 2)])
            return success()
        }
        if let importIndex = arguments.firstIndex(of: "import"),
            importIndex.advanced(by: 2) < arguments.endIndex
        {
            images.insert(arguments[importIndex.advanced(by: 2)])
            if failNextImportAfterMutation {
                failNextImportAfterMutation = false
                return failure("import reply lost")
            }
            return success()
        }
        if let moveIndex = arguments.firstIndex(of: "mv"),
            moveIndex.advanced(by: 2) < arguments.endIndex
        {
            let source = arguments[arguments.index(after: moveIndex)]
            let target = arguments[moveIndex.advanced(by: 2)]
            guard images.remove(source) != nil else { return failure("source does not exist") }
            images.insert(target)
            return success()
        }
        if arguments.contains("flatten") {
            if failNextFlatten {
                failNextFlatten = false
                return failure("flatten interrupted")
            }
            return success()
        }
        if let removeIndex = arguments.firstIndex(of: "rm"),
            arguments.index(after: removeIndex) < arguments.endIndex
        {
            let image = arguments[arguments.index(after: removeIndex)]
            images.remove(image)
            imageMetadata.removeValue(forKey: image)
            return success()
        }
        return success()
    }

    func failCreate(echoing value: String) { createFailureEcho = value }
    func failSnapshotCreateAfterMutation() { failNextSnapshotCreateAfterMutation = true }
    func failImportAfterMutation() { failNextImportAfterMutation = true }
    func failFlattenOnce() { failNextFlatten = true }
    func failSecretUndefineOnce() { failNextSecretUndefine = true }

    private func value(after marker: String, in values: [String]) -> String? {
        guard let index = values.firstIndex(of: marker), values.index(after: index) < values.endIndex else {
            return nil
        }
        return values[values.index(after: index)]
    }

    private func success(_ output: String = "") -> ProcessResult {
        ProcessResult(
            terminationStatus: 0, standardOutput: Data(output.utf8), standardError: Data())
    }

    private func failure(_ output: String) -> ProcessResult {
        ProcessResult(
            terminationStatus: 1, standardOutput: Data(), standardError: Data(output.utf8))
    }
}

private actor BlockingCephCreateRunner {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var didBlockCreate = false
    private var createStarted = false
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ executable: URL, _ arguments: [String]) async -> ProcessResult {
        invocations.append(Invocation(executable: executable.path, arguments: arguments))
        if executable.lastPathComponent == "virsh" { return success() }
        if arguments.contains("info") {
            return failure("rbd: error opening image: No such file or directory")
        }
        if arguments.contains("create"), !didBlockCreate {
            didBlockCreate = true
            createStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { createContinuation = $0 }
        }
        return success()
    }

    func waitUntilCreateStarts() async {
        if createStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }

    private func success() -> ProcessResult {
        ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
    }

    private func failure(_ output: String) -> ProcessResult {
        ProcessResult(
            terminationStatus: 1, standardOutput: Data(), standardError: Data(output.utf8))
    }
}

private struct CephStaticImageSource: ImageSource {
    let path: String
    func localImagePath(for _: ImageInfo, kind _: ArtifactKind) async throws -> String { path }
}

@Suite("Ceph RBD storage backend")
struct CephRBDStorageBackendTests {
    private static let clusterId = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let credentialId = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private static let fsid = "12345678-1234-4234-8234-123456789abc"
    private static let volumeId = "99999999-8888-4777-8666-555555555555"
    private static let secret = "AQB-top-secret-cephx-value=="
    private static let keyring = """
        [client.strato-project]
            key = \(secret)
            caps mon = "profile rbd"
            caps osd = "profile rbd pool=volumes namespace=project-a"
        """

    private func configuration(keyring: String = Self.keyring) -> CephVolumeStorage {
        CephVolumeStorage(
            clusterId: Self.clusterId,
            fsid: Self.fsid,
            pool: "volumes",
            namespace: "project-a",
            clientName: "client.strato-project",
            monEndpoints: ["v2:mon-a.example:3300", "v2:[2001:db8::10]:3300"],
            credentialId: Self.credentialId,
            keyring: keyring,
            messengerMode: .secure)
    }

    private func makeBackend(
        root: String, recorder: CephCommandRecorder,
        imageSource: (any ImageSource)? = nil
    ) -> CephRBDStorageBackend {
        CephRBDStorageBackend(
            logger: Logger(label: "ceph-test"),
            configuration: configuration(),
            imageSource: imageSource,
            rbdPath: "/fake/rbd",
            virshPath: "/fake/virsh",
            qemuImgPath: "/fake/qemu-img",
            clientRoot: root,
            runSubprocess: { executable, arguments in
                await recorder.run(executable, arguments)
            })
    }

    private func imageInfo() -> ImageInfo {
        ImageInfo(
            imageId: UUID(), projectId: UUID(), architecture: .x86_64,
            artifacts: [
                ArtifactInfo(
                    kind: .diskImage, filename: "source.qcow2",
                    checksum: String(repeating: "a", count: 64), size: 1024,
                    downloadURL: "https://control.invalid/source")
            ])
    }

    @Test("Creation pins exact features and reports canonical non-secret RBD coordinates")
    func createUsesPinnedFeaturesAndCanonicalAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-backend-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)

        let attachment = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 1_048_577, format: .raw)

        guard
            case .rbd(
                let pool, let image, let namespace, let user, let monitors, let cluster,
                let credential, let configPath) = attachment
        else {
            Issue.record("expected an RBD attachment")
            return
        }
        #expect(pool == "volumes")
        #expect(image == "strato-volume-\(Self.volumeId)")
        #expect(namespace == "project-a")
        #expect(user == "strato-project")
        #expect(monitors == ["v2:mon-a.example:3300", "v2:[2001:db8::10]:3300"])
        #expect(cluster == Self.clusterId)
        #expect(credential == Self.credentialId)
        #expect(configPath.hasSuffix("/ceph.conf"))
        #expect(!String(describing: attachment).contains(Self.secret))

        let calls = await recorder.invocations
        let create = try #require(calls.first { $0.arguments.contains("create") })
        #expect(create.arguments.contains("2M"))
        let featureIndexes = create.arguments.indices.filter {
            create.arguments[$0] == "--image-feature"
        }
        #expect(featureIndexes.count == 2)
        #expect(create.arguments.contains("layering"))
        #expect(create.arguments.contains("exclusive-lock"))
        #expect(!create.arguments.contains(where: { $0.contains(Self.secret) }))
        #expect(!calls.contains { $0.executable.hasSuffix("virsh") })

        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(config.contains("ms_client_mode = secure"))
        #expect(config.contains("ms_mon_client_mode = secure"))
        #expect(
            config.contains(
                "mon_host = [v2:mon-a.example:3300],[v2:[2001:db8::10]:3300]"))
        let keyringPath = CephRBDStorageBackend.keyringPath(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: keyringPath)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("An out-of-band deterministic image with incompatible features is never adopted")
    func existingImageFeaturesAreValidated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-feature-validation-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder(
            allImagesExist: true,
            features: ["layering", "exclusive-lock", "object-map"])
        let backend = makeBackend(root: root, recorder: recorder)

        do {
            _ = try await backend.createVolume(
                volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)
            Issue.record("an incompatible existing image must fail closed")
        } catch let error as StorageBackendError {
            #expect(error.localizedDescription.contains("feature set is incompatible"))
        }
        let calls = await recorder.invocations
        #expect(!calls.contains { $0.arguments.contains("create") })
    }

    @Test("QEMU preparation installs a libvirt secret through a file, never argv")
    func qemuSecretUsesProtectedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-secret-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)
        let attachment = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)

        try await backend.prepareAttachmentForQEMU(attachment)

        let calls = await recorder.invocations
        let secretSet = try #require(calls.first { $0.arguments.contains("secret-set-value") })
        #expect(secretSet.arguments.contains("--file"))
        #expect(secretSet.arguments.contains("--plain"))
        #expect(!calls.flatMap(\.arguments).contains(where: { $0.contains(Self.secret) }))
        #expect(!calls.flatMap(\.arguments).contains(where: { $0.contains(Self.keyring) }))
    }

    @Test("Subprocess output cannot echo a key into the observed error")
    func commandErrorsAreSecretSafe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-error-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        await recorder.failCreate(echoing: "failed with \(Self.secret)")
        let backend = makeBackend(root: root, recorder: recorder)

        do {
            _ = try await backend.createVolume(
                volumeId: Self.volumeId, sizeBytes: 1024 * 1024, format: .raw)
            Issue.record("expected create to fail")
        } catch {
            #expect(!error.localizedDescription.contains(Self.secret))
            #expect(!String(describing: error).contains(Self.secret))
        }
    }

    @Test("Monitor endpoint validation accepts v2 DNS and bracketed IPv6 only")
    func validatesMonitorEndpoints() {
        #expect(CephRBDStorageBackend.validate(monEndpoint: "v2:mon.example:3300"))
        #expect(CephRBDStorageBackend.validate(monEndpoint: "v2:[2001:db8::1]:3300"))
        #expect(!CephRBDStorageBackend.validate(monEndpoint: "mon.example:6789"))
        #expect(!CephRBDStorageBackend.validate(monEndpoint: "v2:2001:db8::1:3300"))
        #expect(!CephRBDStorageBackend.validate(monEndpoint: "v2:[2001:db8::1]"))
    }

    @Test("Keyring parsing binds the key to the configured cephx client")
    func keyringIdentityIsChecked() throws {
        #expect(
            try CephRBDStorageBackend.parseKey(
                from: Self.keyring, expectedClientName: "client.strato-project") == Self.secret)
        #expect(throws: StorageBackendError.self) {
            try CephRBDStorageBackend.parseKey(
                from: Self.keyring, expectedClientName: "client.someone-else")
        }
    }

    @Test("Ceph size arguments round up to whole MiB")
    func sizeArgumentsUseDocumentedUnits() {
        #expect(CephRBDStorageBackend.sizeArgument(bytes: 1) == "1M")
        #expect(CephRBDStorageBackend.sizeArgument(bytes: 1_048_576) == "1M")
        #expect(CephRBDStorageBackend.sizeArgument(bytes: 1_048_577) == "2M")
    }

    @Test("A qcow2 image is converted to protected raw staging before import")
    func imageImportConvertsNonRawSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-import-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = "/cache/source.qcow2"
        let recorder = CephCommandRecorder(sourceFormat: "qcow2")
        let backend = makeBackend(
            root: root, recorder: recorder,
            imageSource: CephStaticImageSource(path: source))

        _ = try await backend.createVolumeFromImage(
            volumeId: Self.volumeId, imageInfo: imageInfo(), format: .raw,
            artifactKind: .diskImage)

        let calls = await recorder.invocations
        let conversion = try #require(
            calls.first {
                $0.executable.hasSuffix("qemu-img") && $0.arguments.first == "convert"
            })
        #expect(conversion.arguments.prefix(5) == ["convert", "-f", "qcow2", "-O", "raw"])
        let stagedRaw = try #require(conversion.arguments.last)
        #expect(stagedRaw.hasSuffix("/image.raw"))
        let imported = try #require(calls.first { $0.arguments.contains("import") })
        #expect(imported.arguments.contains(stagedRaw))
        #expect(!imported.arguments.contains(source))
        let stagingCoordinate = "volumes/strato-import-\(Self.volumeId)"
        let finalCoordinate = "volumes/strato-volume-\(Self.volumeId)"
        #expect(imported.arguments.contains(stagingCoordinate))
        #expect(!imported.arguments.contains(finalCoordinate))
        let publish = try #require(calls.first { $0.arguments.contains("mv") })
        #expect(publish.arguments.suffix(3) == ["mv", stagingCoordinate, finalCoordinate])
        #expect(!FileManager.default.fileExists(atPath: (stagedRaw as NSString).deletingLastPathComponent))
    }

    @Test("A failed import never publishes or adopts partial image bytes")
    func failedImportCleansDeterministicStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-import-failure-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        await recorder.failImportAfterMutation()
        let backend = makeBackend(
            root: root, recorder: recorder,
            imageSource: CephStaticImageSource(path: "/cache/source.raw"))

        do {
            _ = try await backend.createVolumeFromImage(
                volumeId: Self.volumeId, imageInfo: imageInfo(), format: .raw,
                artifactKind: .diskImage)
            Issue.record("expected import failure")
        } catch is StorageBackendError {}

        #expect(try await backend.inspectVolume(volumeId: Self.volumeId) == nil)
        let stagingCoordinate = "volumes/strato-import-\(Self.volumeId)"
        let finalCoordinate = "volumes/strato-volume-\(Self.volumeId)"
        var calls = await recorder.invocations
        let failedImport = try #require(calls.first { $0.arguments.contains("import") })
        #expect(failedImport.arguments.contains(stagingCoordinate))
        #expect(!failedImport.arguments.contains(finalCoordinate))
        #expect(calls.contains { $0.arguments.suffix(2) == ["rm", stagingCoordinate] })
        #expect(!calls.contains { $0.arguments.contains("mv") })

        _ = try await backend.createVolumeFromImage(
            volumeId: Self.volumeId, imageInfo: imageInfo(), format: .raw,
            artifactKind: .diskImage)
        #expect(try await backend.inspectVolume(volumeId: Self.volumeId) != nil)
        calls = await recorder.invocations
        #expect(
            calls.contains {
                $0.arguments.suffix(3) == ["mv", stagingCoordinate, finalCoordinate]
            })
    }

    @Test("Typed lifecycle operations stay scoped to one namespace and credential")
    func lifecycleCommandsAreScoped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-lifecycle-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)
        let snapshotId = "22222222-3333-4444-8555-666666666666"
        let purgedSnapshotId = "33333333-4444-4555-8666-777777777777"
        let targetId = "77777777-6666-4555-8444-333333333333"
        let coordinate = "volumes/strato-volume-\(Self.volumeId)"
        let targetCoordinate = "volumes/strato-volume-\(targetId)"
        let cloneStagingCoordinate = "volumes/strato-clone-\(targetId)"

        let attachment = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)
        let info = try await backend.volumeInfo(attachment: attachment)
        #expect(info.virtualSize == 2 * 1024 * 1024)
        #expect(info.format == DiskFormat.raw.rawValue)

        try await backend.resizeVolume(
            attachment: attachment, newSizeBytes: 3 * 1024 * 1024 + 1)
        let snapshot = try await backend.createSnapshot(
            volumeId: Self.volumeId, snapshotId: snapshotId, attachment: attachment)
        #expect(
            snapshot
                == "rbd://volumes/project-a/strato-volume-\(Self.volumeId)@strato-snapshot-\(snapshotId)")
        #expect(
            try await backend.createSnapshot(
                volumeId: Self.volumeId, snapshotId: snapshotId, attachment: attachment)
                == snapshot)

        let clone = try await backend.cloneVolume(
            sourceVolumeId: Self.volumeId, sourceAttachment: attachment,
            targetVolumeId: targetId)
        #expect(try await backend.volumeInfo(attachment: clone).virtualSize == 2 * 1024 * 1024)
        try await backend.deleteSnapshot(volumeId: Self.volumeId, snapshotId: snapshotId)
        _ = try await backend.createSnapshot(
            volumeId: Self.volumeId, snapshotId: purgedSnapshotId,
            attachment: attachment)
        try await backend.deleteVolume(volumeId: targetId)
        try await backend.deleteVolume(volumeId: Self.volumeId)

        let calls = await recorder.invocations.filter { $0.executable == "/fake/rbd" }
        let configPath = CephRBDStorageBackend.configPath(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        let keyringPath = CephRBDStorageBackend.keyringPath(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        let scope = [
            "--conf", configPath,
            "--name", "client.strato-project",
            "--keyring", keyringPath,
            "--namespace", "project-a",
        ]
        #expect(calls.allSatisfy { Array($0.arguments.prefix(scope.count)) == scope })

        let resize = try #require(calls.first { $0.arguments.contains("resize") })
        #expect(Array(resize.arguments.dropFirst(scope.count)) == ["resize", coordinate, "--size", "4M"])
        let infoCall = try #require(
            calls.first {
                Array($0.arguments.dropFirst(scope.count))
                    == ["info", "--format", "json", coordinate]
            })
        #expect(infoCall.executable == "/fake/rbd")
        let deterministicSnapshot = "\(coordinate)@strato-snapshot-\(snapshotId)"
        #expect(
            calls.filter {
                Array($0.arguments.dropFirst(scope.count))
                    == ["snap", "create", deterministicSnapshot]
            }.count == 1)
        let cloneCall = try #require(calls.first { $0.arguments.contains("clone") })
        let cloneArguments = Array(cloneCall.arguments.dropFirst(scope.count))
        #expect(cloneArguments.first == "clone")
        #expect(cloneArguments.contains(cloneStagingCoordinate))
        #expect(!cloneArguments.contains(targetCoordinate))
        #expect(cloneArguments.filter { $0 == "--image-feature" }.count == 2)
        #expect(cloneArguments.contains("layering"))
        #expect(cloneArguments.contains("exclusive-lock"))
        #expect(
            calls.contains {
                Array($0.arguments.dropFirst(scope.count))
                    == ["mv", cloneStagingCoordinate, targetCoordinate]
            })
        #expect(
            calls.contains {
                Array($0.arguments.dropFirst(scope.count))
                    == ["snap", "rm", deterministicSnapshot]
            })
        #expect(
            calls.contains {
                Array($0.arguments.dropFirst(scope.count)) == ["rm", targetCoordinate]
            })
        #expect(calls.contains { Array($0.arguments.dropFirst(scope.count)) == ["rm", coordinate] })
        let sourcePurge = try #require(
            calls.firstIndex {
                Array($0.arguments.dropFirst(scope.count)) == ["snap", "purge", coordinate]
            })
        let sourceRemove = try #require(
            calls.firstIndex {
                Array($0.arguments.dropFirst(scope.count)) == ["rm", coordinate]
            })
        #expect(sourcePurge < sourceRemove)
    }

    @Test("Clone replay resumes deterministic staging before publishing the target")
    func cloneReplayFlattensAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-clone-replay-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)
        let targetId = "77777777-6666-4555-8444-333333333333"
        let source = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)
        await recorder.failFlattenOnce()

        do {
            _ = try await backend.cloneVolume(
                sourceVolumeId: Self.volumeId, sourceAttachment: source,
                targetVolumeId: targetId)
            Issue.record("expected interrupted flatten")
        } catch is StorageBackendError {}

        #expect(try await backend.inspectVolume(volumeId: targetId) == nil)
        let replayed = try await backend.cloneVolume(
            sourceVolumeId: Self.volumeId, sourceAttachment: source,
            targetVolumeId: targetId)
        #expect(try await backend.volumeInfo(attachment: replayed).virtualSize == 2 * 1024 * 1024)

        // Model a caller replay after the final name became visible but before
        // it learned that flatten/cleanup completed. The backend re-drives
        // those idempotent operations without issuing a second clone.
        _ = try await backend.cloneVolume(
            sourceVolumeId: Self.volumeId, sourceAttachment: source,
            targetVolumeId: targetId)

        let calls = await recorder.invocations
        #expect(calls.filter { $0.arguments.contains("clone") }.count == 1)
        #expect(calls.filter { $0.arguments.contains("flatten") }.count == 3)
        let staging = "volumes/strato-clone-\(targetId)"
        let target = "volumes/strato-volume-\(targetId)"
        #expect(calls.contains { $0.arguments.suffix(3) == ["mv", staging, target] })
        #expect(calls.contains { $0.arguments.suffix(2) == ["flatten", target] })
        let transientSnapshot = "strato-clone-\(targetId)"
        #expect(
            calls.filter {
                $0.arguments.contains("create")
                    && $0.arguments.contains(where: { $0.hasSuffix("@\(transientSnapshot)") })
            }.count == 1)
        #expect(
            calls.contains {
                $0.arguments.contains("rm")
                    && $0.arguments.contains(where: { $0.hasSuffix("@\(transientSnapshot)") })
            })
    }

    @Test("Deleting an interrupted clone removes staging and its protected source snapshot")
    func deleteCleansInterruptedCloneWithoutNamespaceScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-clone-delete-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)
        let targetId = "77777777-6666-4555-8444-333333333333"
        let source = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)
        await recorder.failFlattenOnce()

        do {
            _ = try await backend.cloneVolume(
                sourceVolumeId: Self.volumeId, sourceAttachment: source,
                targetVolumeId: targetId)
            Issue.record("expected interrupted flatten")
        } catch is StorageBackendError {}

        try await backend.deleteVolume(volumeId: targetId)

        let calls = await recorder.invocations.map(\.arguments)
        let staging = "volumes/strato-clone-\(targetId)"
        let importStaging = "volumes/strato-import-\(targetId)"
        let marker = "volumes/strato-clone-marker-\(targetId)"
        let sourceSnapshot =
            "volumes/strato-volume-\(Self.volumeId)@strato-clone-\(targetId)"
        #expect(calls.contains { $0.suffix(2) == ["rm", staging] })
        #expect(calls.contains { $0.suffix(2) == ["rm", importStaging] })
        #expect(calls.contains { $0.suffix(3) == ["snap", "unprotect", sourceSnapshot] })
        #expect(calls.contains { $0.suffix(2) == ["rm", marker] })
        #expect(!calls.contains { $0.contains("ls") && !$0.contains("snap") })
    }

    @Test("Snapshot replay succeeds when Ceph committed before its reply was lost")
    func snapshotCreateRechecksClusterState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-snapshot-replay-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder()
        let backend = makeBackend(root: root, recorder: recorder)
        let attachment = try await backend.createVolume(
            volumeId: Self.volumeId, sizeBytes: 2 * 1024 * 1024, format: .raw)
        let snapshotId = "22222222-3333-4444-8555-666666666666"
        await recorder.failSnapshotCreateAfterMutation()

        let snapshot = try await backend.createSnapshot(
            volumeId: Self.volumeId, snapshotId: snapshotId, attachment: attachment)

        #expect(snapshot.contains("strato-snapshot-\(snapshotId)"))
        let calls = await recorder.invocations
        #expect(calls.filter { $0.arguments.contains("ls") }.count == 2)
        #expect(calls.filter { $0.arguments.contains("create") }.count == 2)
    }

    @Test("Registry inventory targets desired Ceph ids and never claims a namespace-wide list")
    func registryUsesTargetedInspection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-registry-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = CephCommandRecorder(allImagesExist: true)
        let local = MockStorageBackend(logger: Logger(label: "local-test"))
        let configuration = configuration()
        let registry = StorageBackendRegistry(
            local: local,
            makeCeph: { configuration in
                CephRBDStorageBackend(
                    logger: Logger(label: "ceph-registry-test"),
                    configuration: configuration,
                    rbdPath: "/fake/rbd", virshPath: "/fake/virsh",
                    qemuImgPath: "/fake/qemu-img", clientRoot: root,
                    runSubprocess: { executable, arguments in
                        await recorder.run(executable, arguments)
                    })
            })
        let first = UUID(uuidString: Self.volumeId)!
        let second = UUID(uuidString: "77777777-6666-4555-8444-333333333333")!
        let desired = [first, second].map {
            DesiredVolumeState(
                volumeId: $0, desiredStatus: .present, generation: 1,
                sizeBytes: 1024 * 1024, format: DiskFormat.raw.rawValue,
                storage: .ceph(configuration))
        }

        let inventory = try await registry.inventory(desiredVolumes: desired)
        #expect(Set(inventory.keys) == Set([first.uuidString, second.uuidString]))
        let calls = await recorder.invocations
        #expect(calls.filter { $0.arguments.contains("info") }.count == 2)
        #expect(!calls.contains { $0.arguments.contains("ls") })
    }

    @Test("Credential cleanup removes sensitive files and retries libvirt undefine safely")
    func credentialCleanupIsIdempotentAndSecretSafe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-revoke-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = CephRBDStorageBackend.clientDirectory(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let configPath = CephRBDStorageBackend.configPath(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        let keyringPath = CephRBDStorageBackend.keyringPath(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        let valuePath = (directory as NSString).appendingPathComponent("libvirt-secret.value")
        let markerPath = (directory as NSString).appendingPathComponent("libvirt-secret.xml")
        try "config \(Self.secret)".write(toFile: configPath, atomically: true, encoding: .utf8)
        try Self.keyring.write(toFile: keyringPath, atomically: true, encoding: .utf8)
        try Self.secret.write(toFile: valuePath, atomically: true, encoding: .utf8)
        try "<secret/>".write(toFile: markerPath, atomically: true, encoding: .utf8)
        let recorder = CephCommandRecorder()
        await recorder.failSecretUndefineOnce()
        let revoker = CephCredentialRevoker(
            clientRoot: root, virshPath: "/fake/virsh",
            runSubprocess: { executable, arguments in
                await recorder.run(executable, arguments)
            })

        do {
            try await revoker.revoke(
                clusterId: Self.clusterId, credentialId: Self.credentialId)
            Issue.record("expected the first libvirt cleanup to fail")
        } catch {
            #expect(!error.localizedDescription.contains(Self.secret))
        }
        #expect(!FileManager.default.fileExists(atPath: configPath))
        #expect(!FileManager.default.fileExists(atPath: keyringPath))
        #expect(!FileManager.default.fileExists(atPath: valuePath))
        #expect(FileManager.default.fileExists(atPath: markerPath))

        try await revoker.revoke(clusterId: Self.clusterId, credentialId: Self.credentialId)
        #expect(!FileManager.default.fileExists(atPath: directory))
        let calls = await recorder.invocations.filter {
            $0.executable.hasSuffix("virsh") && $0.arguments.first == "secret-undefine"
        }
        #expect(calls.count == 2)
        #expect(!calls.flatMap(\.arguments).contains { $0.contains(Self.secret) })
    }

    @Test("Revocation deny-lists a credential before waiting for in-flight work")
    func revocationStopsInflightBackendFromRewritingCredential() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-revoke-race-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = BlockingCephCreateRunner()
        let configuration = configuration()
        let registry = StorageBackendRegistry(
            local: MockStorageBackend(logger: Logger(label: "local-revoke-test")),
            makeCeph: { configuration in
                CephRBDStorageBackend(
                    logger: Logger(label: "ceph-revoke-race"),
                    configuration: configuration,
                    rbdPath: "/fake/rbd", virshPath: "/fake/virsh",
                    qemuImgPath: "/fake/qemu-img", clientRoot: root,
                    runSubprocess: { executable, arguments in
                        await runner.run(executable, arguments)
                    })
            },
            credentialRevoker: CephCredentialRevoker(
                clientRoot: root, virshPath: "/fake/virsh",
                runSubprocess: { executable, arguments in
                    await runner.run(executable, arguments)
                }))
        let selected = try await registry.backend(for: .ceph(configuration))
        let create = Task {
            try await selected.createVolume(
                volumeId: Self.volumeId, sizeBytes: 1024 * 1024, format: .raw)
        }
        await runner.waitUntilCreateStarts()
        let revoke = Task {
            try await registry.revokeCephCredential(
                clusterId: Self.clusterId, credentialId: Self.credentialId,
                activeStorages: [], activeAttachments: [])
        }

        var registryDeniedReuse = false
        for _ in 0..<100 {
            await Task.yield()
            do {
                _ = try await registry.backend(for: .ceph(configuration))
            } catch {
                registryDeniedReuse = true
                break
            }
        }
        #expect(registryDeniedReuse)
        await runner.releaseCreate()
        do {
            _ = try await create.value
            Issue.record("in-flight create must fail after credential invalidation")
        } catch is StorageBackendError {}
        try await revoke.value

        let directory = CephRBDStorageBackend.clientDirectory(
            root: root, clusterId: Self.clusterId, credentialId: Self.credentialId)
        #expect(!FileManager.default.fileExists(atPath: directory))
        let countBeforeReuse = await runner.invocations.count
        do {
            _ = try await selected.createVolume(
                volumeId: Self.volumeId, sizeBytes: 1024 * 1024, format: .raw)
            Issue.record("a stale backend reference must stay revoked")
        } catch is StorageBackendError {}
        #expect(await runner.invocations.count == countBeforeReuse)
    }

    @Test("A same-sync storage or VM attachment reference refuses credential cleanup")
    func activeReferencesBlockRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceph-revoke-reference-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let configuration = configuration()
        let registry = StorageBackendRegistry(
            local: MockStorageBackend(logger: Logger(label: "local-reference-test")),
            makeCeph: { _ in
                CephRBDStorageBackend(
                    logger: Logger(label: "ceph-reference-test"),
                    configuration: configuration,
                    rbdPath: "/fake/rbd", virshPath: "/fake/virsh",
                    clientRoot: root,
                    runSubprocess: { _, _ in
                        ProcessResult(
                            terminationStatus: 0, standardOutput: Data(), standardError: Data())
                    })
            }, credentialRevoker: CephCredentialRevoker(clientRoot: root))
        let attachment = DiskAttachment.rbd(
            pool: configuration.pool, image: "strato-volume-\(Self.volumeId)",
            namespace: configuration.namespace, user: "strato-project",
            monEndpoints: configuration.monEndpoints, clusterId: Self.clusterId,
            credentialId: Self.credentialId,
            configPath: CephRBDStorageBackend.configPath(
                root: root, clusterId: Self.clusterId, credentialId: Self.credentialId))

        for (storages, attachments) in [
            ([DesiredVolumeStorage.ceph(configuration)], [DiskAttachment]()),
            ([DesiredVolumeStorage](), [attachment]),
        ] {
            do {
                try await registry.revokeCephCredential(
                    clusterId: Self.clusterId, credentialId: Self.credentialId,
                    activeStorages: storages, activeAttachments: attachments)
                Issue.record("an active credential reference must refuse cleanup")
            } catch is CephCredentialRevocationError {}
        }
        _ = try await registry.backend(for: .ceph(configuration))
    }
}
