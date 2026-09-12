import Foundation
import Logging
import StratoShared

/// An RBD client driver for a Ceph cluster operated outside Strato.
///
/// One instance is scoped to one project namespace and cephx credential. It
/// never starts or manages a Ceph daemon. All CLI calls use a generated config
/// plus a 0600 keyring file; key material is never placed in argv.
public actor CephRBDStorageBackend: CephStorageBackend {
    public static let defaultRBDPath = "/usr/bin/rbd"
    public static let defaultVirshPath = "/usr/bin/virsh"
    public static let defaultClientRoot = CephVolumeStorage.defaultClientRoot
    public static let imagePrefix = CephVolumeStorage.imagePrefix
    public static let snapshotPrefix = "strato-snapshot-"
    private static let importImagePrefix = "strato-import-"
    private static let cloneImagePrefix = "strato-clone-"
    private static let cloneMarkerImagePrefix = "strato-clone-marker-"
    private static let cloneSourceMetadataKey = "strato.clone-source-volume"

    private let logger: Logger
    private var configuration: CephVolumeStorage
    private let imageSource: (any ImageSource)?
    private let rbdPath: String
    private let virshPath: String
    private let qemuImgPath: String
    private let clientRoot: String
    private let runSubprocess: SubprocessRunner
    private var isPrepared = false
    private var isLibvirtSecretPrepared = false
    private var isRevoked = false
    private var activeOperations = 0
    private var revocationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        logger: Logger,
        configuration: CephVolumeStorage,
        imageSource: (any ImageSource)? = nil,
        rbdPath: String = defaultRBDPath,
        virshPath: String = defaultVirshPath,
        qemuImgPath: String = FileSystemStorageBackend.defaultQemuImgPath,
        clientRoot: String = defaultClientRoot,
        runSubprocess: @escaping SubprocessRunner = {
            try await ProcessRunner.run(executableURL: $0, arguments: $1)
        }
    ) {
        self.logger = logger
        self.configuration = configuration
        self.imageSource = imageSource
        self.rbdPath = rbdPath
        self.virshPath = virshPath
        self.qemuImgPath = qemuImgPath
        self.clientRoot = clientRoot
        self.runSubprocess = runSubprocess
    }

    public nonisolated static func imageName(volumeId: String) throws -> String {
        guard let id = UUID(uuidString: volumeId) else {
            throw StorageBackendError.createFailed("volume id '\(volumeId)' is not a UUID")
        }
        return CephVolumeStorage.imageName(volumeId: id)
    }

    public nonisolated static func snapshotName(snapshotId: String) throws -> String {
        guard let id = UUID(uuidString: snapshotId) else {
            throw StorageBackendError.snapshotFailed("snapshot id '\(snapshotId)' is not a UUID")
        }
        return snapshotPrefix + id.uuidString.lowercased()
    }

    public nonisolated static func clientDirectory(
        root: String = defaultClientRoot, clusterId: UUID, credentialId: UUID
    ) -> String {
        CephVolumeStorage.clientDirectory(
            root: root, clusterId: clusterId, credentialId: credentialId)
    }

    public nonisolated static func configPath(
        root: String = defaultClientRoot, clusterId: UUID, credentialId: UUID
    ) -> String {
        CephVolumeStorage.configPath(
            root: root, clusterId: clusterId, credentialId: credentialId)
    }

    public nonisolated static func keyringPath(
        root: String = defaultClientRoot, clusterId: UUID, credentialId: UUID
    ) -> String {
        "\(clientDirectory(root: root, clusterId: clusterId, credentialId: credentialId))/client.keyring"
    }

    public nonisolated static func validate(monEndpoint: String) -> Bool {
        guard monEndpoint.hasPrefix("v2:") else { return false }
        let address = String(monEndpoint.dropFirst(3))
        let host: Substring
        let port: Substring
        if address.hasPrefix("[") {
            guard let closing = address.firstIndex(of: "]"),
                address.index(after: closing) < address.endIndex,
                address[address.index(after: closing)] == ":"
            else { return false }
            host = address[address.index(after: address.startIndex)..<closing]
            port = address[address.index(closing, offsetBy: 2)...]
            guard host.contains(":"),
                host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" })
            else { return false }
        } else {
            guard let separator = address.lastIndex(of: ":") else { return false }
            host = address[..<separator]
            port = address[address.index(after: separator)...]
            // IPv6 literals must be bracketed so the host/port split is
            // unambiguous and libvirt can render it faithfully.
            guard !host.contains(":"),
                host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
            else { return false }
        }
        guard !host.isEmpty, let number = UInt16(port), number > 0 else { return false }
        return true
    }

    /// Native librbd discard is a backend operation and does not depend on a
    /// host filesystem. cache=none/io_uring is deliberately not advertised:
    /// QEMU's RBD driver has its own asynchronous I/O path, and claiming the
    /// POSIX io_uring path without probing it would make domain creation fail.
    public func qemuBlockCapabilities(
        for attachment: DiskAttachment
    ) async -> StorageBlockDeviceCapabilities {
        guard case .rbd = attachment else { return .unsupported }
        return StorageBlockDeviceCapabilities(
            discardSupported: true,
            directIOSupported: false,
            directIOUnavailableReason:
                "native RBD does not use the probed POSIX cache-none/io_uring path")
    }

    public func createVolume(
        volumeId: String, sizeBytes: Int64, format: DiskFormat
    ) async throws -> DiskAttachment {
        try beginOperation()
        defer { endOperation() }
        try requireRaw(format)
        try await prepareClient()
        let attachment = try attachment(volumeId: volumeId)
        if try await inspectVolume(volumeId: volumeId) != nil { return attachment }
        let result = try await runRBD([
            "create", coordinate(for: attachment),
            "--size", Self.sizeArgument(bytes: sizeBytes),
            "--image-format", "2",
            "--image-feature", "layering",
            "--image-feature", "exclusive-lock",
        ])
        try requireSuccess(result, operation: "rbd create", error: StorageBackendError.createFailed)
        logger.info("Ceph RBD volume created", metadata: ["volumeId": .string(volumeId)])
        return attachment
    }

    public func createVolumeFromImage(
        volumeId: String, imageInfo: ImageInfo, format: DiskFormat, artifactKind: ArtifactKind
    ) async throws -> DiskAttachment {
        try beginOperation()
        defer { endOperation() }
        try requireRaw(format)
        guard let imageSource else { throw StorageBackendError.imageSourceUnavailable }
        try await prepareClient()
        let finalAttachment = try attachment(volumeId: volumeId)
        if try await inspectVolume(volumeId: volumeId) != nil { return finalAttachment }
        let staging = try attachment(
            image: Self.temporaryImageName(prefix: Self.importImagePrefix, volumeId: volumeId))
        try await removeImageIfPresent(staging, operation: "rbd import staging cleanup")
        let source = try await imageSource.localImagePath(for: imageInfo, kind: artifactKind)
        let preparedSource = try await rawImportSource(from: source)
        defer {
            if let directory = preparedSource.temporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let result = try await runRBD([
            "import", preparedSource.path, coordinate(for: staging),
            "--image-format", "2",
            "--image-feature", "layering",
            "--image-feature", "exclusive-lock",
        ])
        guard result.terminationStatus == 0 else {
            try? await removeImageIfPresent(staging, operation: "rbd import failure cleanup")
            throw sanitizedFailure(
                result, operation: "rbd import", error: StorageBackendError.createFailed)
        }
        try await publish(
            staging: staging, as: finalAttachment, operation: "rbd import publish",
            error: StorageBackendError.createFailed)
        logger.info("Image imported into Ceph RBD", metadata: ["volumeId": .string(volumeId)])
        return finalAttachment
    }

    public func materializeDisk(
        at path: String, from imageInfo: ImageInfo, format: DiskFormat, artifactKind: ArtifactKind
    ) async throws -> DiskAttachment {
        try beginOperation()
        defer { endOperation() }
        throw StorageBackendError.createFailed(
            "Ceph RBD materialization requires a managed volume id, not path '\(path)'")
    }

    public func deleteVolume(volumeId: String) async throws {
        try beginOperation()
        defer { endOperation() }
        try await prepareClient()
        let final = try attachment(volumeId: volumeId)
        let importStaging = try attachment(
            image: Self.temporaryImageName(prefix: Self.importImagePrefix, volumeId: volumeId))
        let cloneStaging = try attachment(
            image: Self.temporaryImageName(prefix: Self.cloneImagePrefix, volumeId: volumeId))
        let cloneMarker = try attachment(
            image: Self.temporaryImageName(prefix: Self.cloneMarkerImagePrefix, volumeId: volumeId))
        let cloneSource = try await cloneSourceVolumeId(from: cloneMarker)

        // A delete authorizes every deterministic image created on behalf of
        // this target, including work that crashed before the final `rbd mv`.
        // Remove the child first so its protected parent snapshot can then be
        // unprotected without a dependency.
        for image in [cloneStaging, importStaging, final] {
            try await purgeAndRemoveImage(image, operation: "rbd delete")
        }
        if let cloneSource {
            let source = try attachment(volumeId: cloneSource.uuidString)
            let snapshot = try Self.temporaryImageName(
                prefix: Self.cloneImagePrefix, volumeId: volumeId)
            try await removeCloneSnapshot("\(coordinate(for: source))@\(snapshot)")
        }
        try await purgeAndRemoveImage(cloneMarker, operation: "rbd clone marker delete")
        logger.info("Ceph RBD volume removed", metadata: ["volumeId": .string(volumeId)])
    }

    public func resizeVolume(attachment: DiskAttachment, newSizeBytes: Int64) async throws {
        try beginOperation()
        defer { endOperation() }
        try validate(attachment: attachment)
        try await prepareClient()
        let result = try await runRBD([
            "resize", coordinate(for: attachment), "--size", Self.sizeArgument(bytes: newSizeBytes),
        ])
        try requireSuccess(result, operation: "rbd resize", error: StorageBackendError.resizeFailed)
    }

    public func createSnapshot(
        volumeId: String, snapshotId: String, attachment: DiskAttachment
    ) async throws -> String {
        try beginOperation()
        defer { endOperation() }
        try validate(attachment: attachment)
        try await prepareClient()
        let snapshot = try Self.snapshotName(snapshotId: snapshotId)
        let value = "\(coordinate(for: attachment))@\(snapshot)"
        if try await snapshotExists(snapshot, on: attachment) {
            return snapshotReference(snapshot, on: attachment)
        }
        let result = try await runRBD(["snap", "create", value])
        if result.terminationStatus != 0 {
            // A crash can occur after Ceph commits the deterministic snapshot
            // but before the agent persists SnapshotRecord. Re-read cluster
            // state so that replay converges even when the original command's
            // reply was lost or a concurrent retry observed EEXIST.
            guard try await snapshotExists(snapshot, on: attachment) else {
                throw sanitizedFailure(
                    result, operation: "rbd snap create", error: StorageBackendError.snapshotFailed)
            }
        }
        return snapshotReference(snapshot, on: attachment)
    }

    public func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        try beginOperation()
        defer { endOperation() }
        try await prepareClient()
        let disk = try attachment(volumeId: volumeId)
        let snapshot = try Self.snapshotName(snapshotId: snapshotId)
        let result = try await runRBD(["snap", "rm", "\(coordinate(for: disk))@\(snapshot)"])
        if result.terminationStatus != 0, !Self.isNotFound(result) {
            throw sanitizedFailure(
                result, operation: "rbd snap rm", error: StorageBackendError.snapshotFailed)
        }
    }

    public func cloneVolume(
        sourceVolumeId: String, sourceAttachment: DiskAttachment, targetVolumeId: String
    ) async throws -> DiskAttachment {
        try beginOperation()
        defer { endOperation() }
        try validate(attachment: sourceAttachment)
        guard image(of: sourceAttachment) == (try Self.imageName(volumeId: sourceVolumeId)) else {
            throw StorageBackendError.cloneFailed(
                "source attachment does not match the requested source volume")
        }
        try await prepareClient()
        let target = try attachment(volumeId: targetVolumeId)
        let staging = try attachment(
            image: Self.temporaryImageName(
                prefix: Self.cloneImagePrefix, volumeId: targetVolumeId))
        let temporarySnapshot = try Self.temporaryImageName(
            prefix: Self.cloneImagePrefix, volumeId: targetVolumeId)
        let sourceSnapshot = "\(coordinate(for: sourceAttachment))@\(temporarySnapshot)"
        let marker = try attachment(
            image: Self.temporaryImageName(
                prefix: Self.cloneMarkerImagePrefix, volumeId: targetVolumeId))
        if try await imageExists(target) {
            try await flatten(target, allowingAlreadyFlat: true)
            try await removeCloneSnapshot(sourceSnapshot)
            try await purgeAndRemoveImage(marker, operation: "rbd clone marker cleanup")
            return target
        }
        try await ensureCloneMarker(marker, sourceVolumeId: sourceVolumeId)
        if try await imageExists(staging) {
            try await finishClone(
                staging: staging, target: target, sourceSnapshot: sourceSnapshot,
                marker: marker)
            return target
        }

        // A short-lived protected snapshot gives `rbd clone` its required COW
        // parent. Everything remains under deterministic staging identities
        // until flatten and cleanup finish; only `rbd mv` publishes the final
        // image name that targeted inventory can report as present.
        if !(try await snapshotExists(temporarySnapshot, on: sourceAttachment)) {
            let create = try await runRBD(["snap", "create", sourceSnapshot])
            if create.terminationStatus != 0,
                !(try await snapshotExists(temporarySnapshot, on: sourceAttachment))
            {
                throw sanitizedFailure(
                    create, operation: "rbd clone snapshot",
                    error: StorageBackendError.cloneFailed)
            }
        }
        let protect = try await runRBD(["snap", "protect", sourceSnapshot])
        if protect.terminationStatus != 0, !Self.isAlreadyProtected(protect) {
            throw sanitizedFailure(
                protect, operation: "rbd snap protect", error: StorageBackendError.cloneFailed)
        }
        let clone = try await runRBD([
            "clone", sourceSnapshot, coordinate(for: staging),
            "--image-feature", "layering",
            "--image-feature", "exclusive-lock",
        ])
        if clone.terminationStatus != 0, !(try await imageExists(staging)) {
            throw sanitizedFailure(
                clone, operation: "rbd clone", error: StorageBackendError.cloneFailed)
        }
        try await finishClone(
            staging: staging, target: target, sourceSnapshot: sourceSnapshot,
            marker: marker)
        return target
    }

    public func volumeInfo(attachment: DiskAttachment) async throws -> VolumeInfoResult {
        try beginOperation()
        defer { endOperation() }
        try validate(attachment: attachment)
        try await prepareClient()
        let result = try await runRBD(["info", "--format", "json", coordinate(for: attachment)])
        try requireSuccess(result, operation: "rbd info", error: StorageBackendError.infoFailed)
        let size = try validatedImageSize(result.standardOutput)
        return VolumeInfoResult(
            actualSize: size, virtualSize: size, format: DiskFormat.raw.rawValue,
            dirty: false, encrypted: false)
    }

    public func inspectVolume(volumeId: String) async throws -> DiskAttachment? {
        try beginOperation()
        defer { endOperation() }
        try await prepareClient()
        let disk = try attachment(volumeId: volumeId)
        return try await imageExists(disk) ? disk : nil
    }

    public func listVolumes() async throws -> [String: DiskAttachment] {
        try beginOperation()
        defer { endOperation() }
        try await prepareClient()
        let result = try await runRBD(["ls", "--format", "json", configuration.pool])
        try requireSuccess(result, operation: "rbd ls", error: StorageBackendError.infoFailed)
        guard let names = try? JSONDecoder().decode([String].self, from: result.standardOutput) else {
            throw StorageBackendError.infoFailed("rbd ls returned malformed JSON")
        }
        var volumes: [String: DiskAttachment] = [:]
        for name in names where name.hasPrefix(Self.imagePrefix) {
            let suffix = String(name.dropFirst(Self.imagePrefix.count))
            guard let id = UUID(uuidString: suffix) else { continue }
            volumes[id.uuidString] = try attachment(image: name)
        }
        return volumes
    }

    // MARK: - Client material

    private func prepareClient() async throws {
        try requireNotRevoked()
        guard !isPrepared else { return }
        try validateConfiguration()

        let configPath = Self.configPath(
            root: clientRoot, clusterId: configuration.clusterId,
            credentialId: configuration.credentialId)
        let keyringPath = Self.keyringPath(
            root: clientRoot, clusterId: configuration.clusterId,
            credentialId: configuration.credentialId)
        let writer = DurableFileWriter()
        try writer.write(Data(renderConfig().utf8), to: configPath, permissions: 0o600)
        try writer.write(Data(configuration.keyring.utf8), to: keyringPath, permissions: 0o600)

        isPrepared = true
    }

    public func prepareAttachmentForQEMU(_ attachment: DiskAttachment) async throws {
        try beginOperation()
        defer { endOperation() }
        try validate(attachment: attachment)
        try await prepareClient()
        guard !isLibvirtSecretPrepared else { return }
        let configPath = Self.configPath(
            root: clientRoot, clusterId: configuration.clusterId,
            credentialId: configuration.credentialId)
        let directory = (configPath as NSString).deletingLastPathComponent
        let secretXMLPath = "\(directory)/libvirt-secret.xml"
        let secretValuePath = "\(directory)/libvirt-secret.value"
        let writer = DurableFileWriter()

        // Libvirt needs only the cephx key value, not the whole keyring. Parse
        // it into a protected file because `--file --plain` is the only safe
        // virsh interface: the key never appears in argv or a process listing.
        let secretValue = try Self.parseKey(
            from: configuration.keyring, expectedClientName: configuration.clientName)
        try writer.write(Data(secretValue.utf8), to: secretValuePath, permissions: 0o600)
        defer { try? FileManager.default.removeItem(atPath: secretValuePath) }
        let usage =
            "strato-ceph-\(configuration.clusterId.uuidString.lowercased())-\(configuration.credentialId.uuidString.lowercased())"
        let xml = """
            <secret ephemeral='no' private='yes'>
              <uuid>\(configuration.credentialId.uuidString.lowercased())</uuid>
              <description>Strato Ceph client credential</description>
              <usage type='ceph'><name>\(usage)</name></usage>
            </secret>
            """
        try writer.write(Data(xml.utf8), to: secretXMLPath, permissions: 0o600)

        let define = try await runSubprocess(
            URL(fileURLWithPath: virshPath), ["secret-define", "--file", secretXMLPath])
        try requireNotRevoked()
        try requireSuccess(
            define, operation: "virsh secret-define", error: StorageBackendError.hostMisconfiguration)
        let set = try await runSubprocess(
            URL(fileURLWithPath: virshPath),
            [
                "secret-set-value", "--secret", configuration.credentialId.uuidString.lowercased(),
                "--file", secretValuePath, "--plain",
            ])
        try requireNotRevoked()
        try requireSuccess(
            set, operation: "virsh secret-set-value", error: StorageBackendError.hostMisconfiguration)
        isLibvirtSecretPrepared = true
    }

    /// Permanently invalidates this cached actor. The credential is blanked
    /// immediately, new calls fail at `beginOperation`, and cleanup waits until
    /// any operation that yielded before invalidation has observed the flag and
    /// unwound. That barrier prevents a late `prepareClient` or libvirt command
    /// from recreating material after the registry removes it.
    public func invalidateForCredentialRevocation() async {
        guard !isRevoked else {
            if activeOperations > 0 {
                await withCheckedContinuation { revocationWaiters.append($0) }
            }
            return
        }
        isRevoked = true
        configuration = CephVolumeStorage(
            clusterId: configuration.clusterId,
            fsid: configuration.fsid,
            pool: configuration.pool,
            namespace: configuration.namespace,
            clientName: configuration.clientName,
            monEndpoints: configuration.monEndpoints,
            credentialId: configuration.credentialId,
            keyring: "",
            messengerMode: configuration.messengerMode)
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { revocationWaiters.append($0) }
    }

    public nonisolated static func sizeArgument(bytes: Int64) -> String {
        let mebibyte: Int64 = 1024 * 1024
        let positive = max(1, bytes)
        let mebibytes = positive / mebibyte + (positive % mebibyte == 0 ? 0 : 1)
        return "\(mebibytes)M"
    }

    public nonisolated static func parseKey(
        from keyring: String, expectedClientName: String
    ) throws -> String {
        var section: String?
        var matches: [String] = []
        for rawLine in keyring.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard section == expectedClientName,
                let separator = line.firstIndex(of: "=")
            else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "key" else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { matches.append(value) }
        }
        guard matches.count == 1, let key = matches.first else {
            throw StorageBackendError.hostMisconfiguration(
                "Ceph keyring must contain exactly one non-empty 'key = …' entry in [\(expectedClientName)]")
        }
        return key
    }

    private func validateConfiguration() throws {
        guard configuration.messengerMode == .secure else {
            throw StorageBackendError.hostMisconfiguration("Ceph messenger mode must be secure")
        }
        guard UUID(uuidString: configuration.fsid) != nil else {
            throw StorageBackendError.hostMisconfiguration("Ceph FSID is not a UUID")
        }
        guard Self.isSafeName(configuration.pool),
            Self.isSafeName(configuration.namespace),
            configuration.clientName.hasPrefix("client."),
            Self.isSafeName(configuration.clientName)
        else {
            throw StorageBackendError.hostMisconfiguration(
                "Ceph pool, namespace, and client name must be non-empty")
        }
        guard !configuration.monEndpoints.isEmpty,
            configuration.monEndpoints.allSatisfy(Self.validate(monEndpoint:))
        else {
            throw StorageBackendError.hostMisconfiguration(
                "Ceph monitor endpoints must be explicit v2 host:port values; bracket IPv6 literals")
        }
    }

    private nonisolated static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("/")
            && value.allSatisfy { !$0.isWhitespace && !$0.isNewline && $0 != "," && $0 != "=" }
    }

    private func renderConfig() -> String {
        let monitorVectors = configuration.monEndpoints
            .map { "[\($0)]" }
            .joined(separator: ",")
        return """
            [global]
            fsid = \(configuration.fsid)
            mon_host = \(monitorVectors)
            ms_client_mode = secure
            ms_mon_client_mode = secure
            auth_client_required = cephx
            keyring = \(Self.keyringPath(root: clientRoot, clusterId: configuration.clusterId, credentialId: configuration.credentialId))
            """
    }

    private func runRBD(_ arguments: [String]) async throws -> ProcessResult {
        try requireNotRevoked()
        let common = [
            "--conf",
            Self.configPath(
                root: clientRoot, clusterId: configuration.clusterId,
                credentialId: configuration.credentialId),
            "--name", configuration.clientName,
            "--keyring",
            Self.keyringPath(
                root: clientRoot, clusterId: configuration.clusterId,
                credentialId: configuration.credentialId),
            "--namespace", configuration.namespace,
        ]
        let result = try await runSubprocess(URL(fileURLWithPath: rbdPath), common + arguments)
        try requireNotRevoked()
        return result
    }

    private func rawImportSource(
        from source: String
    ) async throws -> (path: String, temporaryDirectory: URL?) {
        let info = try await runSubprocess(
            URL(fileURLWithPath: qemuImgPath), ["info", "--output=json", source])
        try requireNotRevoked()
        guard info.terminationStatus == 0 else {
            throw StorageBackendError.createFailed(
                "qemu-img info exited with status \(info.terminationStatus)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: info.standardOutput) as? [String: Any],
            let format = object["format"] as? String
        else {
            throw StorageBackendError.createFailed("qemu-img info returned malformed JSON")
        }
        guard format != DiskFormat.raw.rawValue else { return (source, nil) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strato-rbd-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let converted = directory.appendingPathComponent("image.raw").path
        do {
            let conversion = try await runSubprocess(
                URL(fileURLWithPath: qemuImgPath),
                ["convert", "-f", format, "-O", DiskFormat.raw.rawValue, source, converted])
            try requireNotRevoked()
            guard conversion.terminationStatus == 0 else {
                throw StorageBackendError.createFailed(
                    "qemu-img convert exited with status \(conversion.terminationStatus)")
            }
            return (converted, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func attachment(volumeId: String) throws -> DiskAttachment {
        try attachment(image: Self.imageName(volumeId: volumeId))
    }

    private nonisolated static func temporaryImageName(
        prefix: String, volumeId: String
    ) throws -> String {
        guard let id = UUID(uuidString: volumeId) else {
            throw StorageBackendError.createFailed("volume id '\(volumeId)' is not a UUID")
        }
        return prefix + id.uuidString.lowercased()
    }

    private func attachment(image: String) throws -> DiskAttachment {
        .rbd(
            pool: configuration.pool,
            image: image,
            namespace: configuration.namespace,
            user: cephUser,
            monEndpoints: configuration.monEndpoints,
            clusterId: configuration.clusterId,
            credentialId: configuration.credentialId,
            configPath: Self.configPath(
                root: clientRoot, clusterId: configuration.clusterId,
                credentialId: configuration.credentialId))
    }

    private var cephUser: String {
        configuration.clientName.hasPrefix("client.")
            ? String(configuration.clientName.dropFirst("client.".count))
            : configuration.clientName
    }

    private func coordinate(for attachment: DiskAttachment) -> String {
        "\(configuration.pool)/\(image(of: attachment))"
    }

    private func imageExists(_ attachment: DiskAttachment) async throws -> Bool {
        let result = try await runRBD([
            "info", "--format", "json", coordinate(for: attachment),
        ])
        if result.terminationStatus == 0 {
            _ = try validatedImageSize(result.standardOutput)
            return true
        }
        if Self.isNotFound(result) { return false }
        throw sanitizedFailure(
            result, operation: "rbd info", error: StorageBackendError.infoFailed)
    }

    private func removeImageIfPresent(
        _ attachment: DiskAttachment, operation: String
    ) async throws {
        let result = try await runRBD(["rm", coordinate(for: attachment)])
        guard result.terminationStatus == 0 || Self.isNotFound(result) else {
            throw sanitizedFailure(
                result, operation: operation, error: StorageBackendError.createFailed)
        }
    }

    private func publish(
        staging: DiskAttachment, as target: DiskAttachment, operation: String,
        error: (String) -> StorageBackendError
    ) async throws {
        let result = try await runRBD([
            "mv", coordinate(for: staging), coordinate(for: target),
        ])
        if result.terminationStatus != 0, !(try await imageExists(target)) {
            throw sanitizedFailure(result, operation: operation, error: error)
        }
    }

    private func finishClone(
        staging: DiskAttachment, target: DiskAttachment, sourceSnapshot: String,
        marker: DiskAttachment
    ) async throws {
        try await flatten(staging, allowingAlreadyFlat: true)
        try await removeCloneSnapshot(sourceSnapshot)
        try await publish(
            staging: staging, as: target, operation: "rbd clone publish",
            error: StorageBackendError.cloneFailed)
        try await purgeAndRemoveImage(marker, operation: "rbd clone marker cleanup")
    }

    /// Writes the source identity into a target-derived RBD marker before
    /// creating the protected source snapshot. A later delete knows only the
    /// target id; this marker lets it clean that exact source snapshot without
    /// a namespace-wide scan, even after an agent crash or host move.
    private func ensureCloneMarker(
        _ marker: DiskAttachment, sourceVolumeId: String
    ) async throws {
        if !(try await imageExists(marker)) {
            let create = try await runRBD([
                "create", coordinate(for: marker),
                "--size", "1M",
                "--image-format", "2",
                "--image-feature", "layering",
                "--image-feature", "exclusive-lock",
            ])
            if create.terminationStatus != 0, !(try await imageExists(marker)) {
                throw sanitizedFailure(
                    create, operation: "rbd clone marker create",
                    error: StorageBackendError.cloneFailed)
            }
        }
        if let recorded = try await cloneSourceVolumeId(from: marker) {
            guard recorded == UUID(uuidString: sourceVolumeId) else {
                throw StorageBackendError.cloneFailed(
                    "clone marker belongs to a different source volume")
            }
            return
        }
        guard let sourceId = UUID(uuidString: sourceVolumeId) else {
            throw StorageBackendError.cloneFailed("source volume id is not a UUID")
        }
        let set = try await runRBD([
            "image-meta", "set", coordinate(for: marker), Self.cloneSourceMetadataKey,
            sourceId.uuidString.lowercased(),
        ])
        try requireSuccess(
            set, operation: "rbd clone marker metadata",
            error: StorageBackendError.cloneFailed)
    }

    private func cloneSourceVolumeId(from marker: DiskAttachment) async throws -> UUID? {
        guard try await imageExists(marker) else { return nil }
        let result = try await runRBD([
            "image-meta", "get", coordinate(for: marker), Self.cloneSourceMetadataKey,
        ])
        if result.terminationStatus != 0, Self.isMetadataMissing(result) { return nil }
        try requireSuccess(
            result, operation: "rbd clone marker read",
            error: StorageBackendError.deleteFailed)
        let value = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, let id = UUID(uuidString: value) else {
            throw StorageBackendError.deleteFailed("rbd clone marker contains an invalid source id")
        }
        return id
    }

    private func purgeAndRemoveImage(
        _ attachment: DiskAttachment, operation: String
    ) async throws {
        let purge = try await runRBD(["snap", "purge", coordinate(for: attachment)])
        if purge.terminationStatus != 0, !Self.isNotFound(purge) {
            throw sanitizedFailure(
                purge, operation: "\(operation) snapshot purge",
                error: StorageBackendError.deleteFailed)
        }
        let remove = try await runRBD(["rm", coordinate(for: attachment)])
        if remove.terminationStatus != 0, !Self.isNotFound(remove) {
            throw sanitizedFailure(
                remove, operation: operation, error: StorageBackendError.deleteFailed)
        }
    }

    private func flatten(
        _ attachment: DiskAttachment, allowingAlreadyFlat: Bool
    ) async throws {
        let result = try await runRBD(["flatten", coordinate(for: attachment)])
        guard
            result.terminationStatus == 0
                || (allowingAlreadyFlat && Self.isAlreadyFlat(result))
        else {
            throw sanitizedFailure(
                result, operation: "rbd flatten", error: StorageBackendError.cloneFailed)
        }
    }

    private func removeCloneSnapshot(_ sourceSnapshot: String) async throws {
        let unprotect = try await runRBD(["snap", "unprotect", sourceSnapshot])
        guard
            unprotect.terminationStatus == 0
                || Self.isNotFound(unprotect)
                || Self.isNotProtected(unprotect)
        else {
            throw sanitizedFailure(
                unprotect, operation: "rbd snap unprotect",
                error: StorageBackendError.cloneFailed)
        }
        let remove = try await runRBD(["snap", "rm", sourceSnapshot])
        guard remove.terminationStatus == 0 || Self.isNotFound(remove) else {
            throw sanitizedFailure(
                remove, operation: "rbd clone snapshot cleanup",
                error: StorageBackendError.cloneFailed)
        }
    }

    private struct SnapshotListing: Decodable {
        let name: String
    }

    private func snapshotExists(
        _ snapshot: String, on attachment: DiskAttachment
    ) async throws -> Bool {
        let result = try await runRBD([
            "snap", "ls", coordinate(for: attachment), "--format", "json",
        ])
        try requireSuccess(
            result, operation: "rbd snap ls", error: StorageBackendError.snapshotFailed)
        guard
            let snapshots = try? JSONDecoder().decode(
                [SnapshotListing].self, from: result.standardOutput)
        else {
            throw StorageBackendError.snapshotFailed("rbd snap ls returned malformed JSON")
        }
        return snapshots.contains { $0.name == snapshot }
    }

    private func snapshotReference(
        _ snapshot: String, on attachment: DiskAttachment
    ) -> String {
        "rbd://\(configuration.pool)/\(configuration.namespace)/\(image(of: attachment))@\(snapshot)"
    }

    private func image(of attachment: DiskAttachment) -> String {
        guard case .rbd(_, let image, _, _, _, _, _, _) = attachment else { return "" }
        return image
    }

    /// Every deterministic image name is still untrusted cluster state: an
    /// operator or compromised client could create it out of band. Validate
    /// the format and exact feature set before any idempotent path adopts it.
    /// This is especially important for krbd, which refuses unsupported image
    /// features at map time rather than degrading them.
    private func validatedImageSize(_ data: Data) throws -> Int64 {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let size = (object["size"] as? NSNumber)?.int64Value,
            let format = (object["format"] as? NSNumber)?.intValue,
            let rawFeatures = object["features"] as? [Any]
        else {
            throw StorageBackendError.infoFailed("rbd info returned malformed JSON")
        }
        let features = rawFeatures.compactMap { value -> String? in
            if let value = value as? String { return value }
            return (value as? [String: Any])?["feature"] as? String
        }
        let required = Set(["layering", "exclusive-lock"])
        guard format == 2, features.count == rawFeatures.count, Set(features) == required else {
            throw StorageBackendError.infoFailed(
                "RBD image format or feature set is incompatible; expected format 2 with exactly layering and exclusive-lock"
            )
        }
        return size
    }

    private func validate(attachment: DiskAttachment) throws {
        guard
            case .rbd(
                let pool, _, let namespace, let user, let monEndpoints, let clusterId,
                let credentialId, let configPath) = attachment,
            pool == configuration.pool,
            namespace == configuration.namespace,
            user == cephUser,
            monEndpoints == configuration.monEndpoints,
            clusterId == configuration.clusterId,
            credentialId == configuration.credentialId,
            configPath
                == Self.configPath(
                    root: clientRoot, clusterId: configuration.clusterId,
                    credentialId: configuration.credentialId)
        else {
            throw StorageBackendError.infoFailed(
                "RBD attachment does not belong to this cluster, namespace, and credential")
        }
    }

    private func requireRaw(_ format: DiskFormat) throws {
        guard format == .raw else { throw StorageBackendError.unsupportedFormat(format.rawValue) }
    }

    private func beginOperation() throws {
        try requireNotRevoked()
        activeOperations += 1
    }

    private func endOperation() {
        precondition(activeOperations > 0)
        activeOperations -= 1
        guard activeOperations == 0, !revocationWaiters.isEmpty else { return }
        let waiters = revocationWaiters
        revocationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func requireNotRevoked() throws {
        guard !isRevoked else {
            throw StorageBackendError.hostMisconfiguration(
                "Ceph credential has been permanently revoked on this agent")
        }
    }

    private func requireSuccess(
        _ result: ProcessResult, operation: String,
        error: (String) -> StorageBackendError
    ) throws {
        guard result.terminationStatus == 0 else {
            throw sanitizedFailure(result, operation: operation, error: error)
        }
    }

    private func sanitizedFailure(
        _ result: ProcessResult, operation: String,
        error: (String) -> StorageBackendError
    ) -> StorageBackendError {
        // Command output is intentionally not propagated. Apart from keeping
        // failures stable across Ceph versions, this ensures an unexpectedly
        // chatty client cannot echo credential material into logs or observed
        // convergence errors.
        error("\(operation) exited with status \(result.terminationStatus)")
    }

    private nonisolated static func isNotFound(_ result: ProcessResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("no such file or directory")
            || output.contains("no such file")
            || output.contains("error opening image")
            || output.contains("does not exist")
    }

    private nonisolated static func isAlreadyProtected(_ result: ProcessResult) -> Bool {
        result.combinedOutput.lowercased().contains("already protected")
    }

    private nonisolated static func isNotProtected(_ result: ProcessResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("not protected") || output.contains("is unprotected")
    }

    private nonisolated static func isAlreadyFlat(_ result: ProcessResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("does not have a parent")
            || output.contains("has no parent")
            || output.contains("no parent")
    }

    private nonisolated static func isMetadataMissing(_ result: ProcessResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("metadata not found")
            || output.contains("no such key")
            || output.contains("does not exist")
    }
}
