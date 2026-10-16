import Crypto
import Foundation
import StratoShared

/// A host-only realization of a canonical storage attachment.
///
/// `canonical` is what remains in manifests and observed state. `realized` is
/// the temporary path Firecracker can open on this one host.
public struct FirecrackerRealizedDisk: Sendable, Equatable {
    public let canonical: DiskAttachment
    public let realized: DiskAttachment
    public let readOnly: Bool

    public init(canonical: DiskAttachment, realized: DiskAttachment, readOnly: Bool = false) {
        self.canonical = canonical
        self.realized = realized
        self.readOnly = readOnly
    }
}

public protocol FirecrackerDiskRealizing: Actor {
    func realize(_ attachment: DiskAttachment, readOnly: Bool) async throws -> FirecrackerRealizedDisk
    func adopt(_ attachment: DiskAttachment, readOnly: Bool) async throws -> FirecrackerRealizedDisk
    func release(_ disk: FirecrackerRealizedDisk) async throws
}

extension FirecrackerDiskRealizing {
    public func adopt(
        _ attachment: DiskAttachment, readOnly: Bool
    ) async throws -> FirecrackerRealizedDisk {
        try await realize(attachment, readOnly: readOnly)
    }
}

/// Realizes local attachments without changing their identity.
public actor LocalFirecrackerDiskRealizer: FirecrackerDiskRealizing {
    public init() {}

    public func realize(_ attachment: DiskAttachment, readOnly: Bool) async throws -> FirecrackerRealizedDisk {
        guard case .rbd = attachment else {
            return FirecrackerRealizedDisk(
                canonical: attachment, realized: attachment, readOnly: readOnly)
        }
        throw StorageBackendError.hostMisconfiguration(
            "Firecracker RBD attachment requires a krbd disk realizer")
    }

    public func release(_: FirecrackerRealizedDisk) async throws {}
}

/// Maps native RBD attachments through krbd for Firecracker and reference
/// counts mappings shared by multiple local realizations.
public actor KRBDDiskRealizer: FirecrackerDiskRealizing {
    private struct Mapping: Sendable {
        let path: String
        var references: Int
    }

    private struct MappedDevice: Decodable {
        let name: String?
        let image: String?
        let pool: String
        let namespace: String?
        let device: String

        var imageName: String { name ?? image ?? "" }
    }

    private let rbdPath: String
    private let runSubprocess: SubprocessRunner
    private let mappingStatePath: String
    private let deviceExists: @Sendable (String) -> Bool
    private let readTextFile: @Sendable (String) throws -> String
    private var mappings: [String: Mapping]

    public init(
        rbdPath: String = CephRBDStorageBackend.defaultRBDPath,
        mappingStatePath: String = "/var/lib/strato/ceph/krbd-mappings.json",
        deviceExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        readTextFile: @escaping @Sendable (String) throws -> String = {
            try String(contentsOfFile: $0, encoding: .utf8)
        },
        runSubprocess: @escaping SubprocessRunner = SubprocessBudget.run
    ) {
        self.rbdPath = rbdPath
        self.mappingStatePath = mappingStatePath
        self.deviceExists = deviceExists
        self.readTextFile = readTextFile
        self.runSubprocess = runSubprocess
        if let data = try? Data(contentsOf: URL(fileURLWithPath: mappingStatePath)),
            let persisted = try? JSONDecoder().decode([String: String].self, from: data)
        {
            self.mappings = persisted.reduce(into: [:]) { result, entry in
                result[entry.key] = Mapping(path: entry.value, references: 0)
            }
        } else {
            self.mappings = [:]
        }
    }

    public func realize(
        _ attachment: DiskAttachment, readOnly: Bool
    ) async throws -> FirecrackerRealizedDisk {
        guard
            case .rbd(
                let pool, let image, let namespace, let user, _, _, _, let configPath) = attachment
        else {
            return FirecrackerRealizedDisk(
                canonical: attachment, realized: attachment, readOnly: readOnly)
        }

        let key = mappingKey(for: attachment, readOnly: readOnly)
        if var existing = mappings[key] {
            if deviceExists(existing.path),
                try await mappingMatches(
                    path: existing.path, attachment: attachment, readOnly: readOnly)
            {
                existing.references += 1
                mappings[key] = existing
                return FirecrackerRealizedDisk(
                    canonical: attachment, realized: .blockDevice(path: existing.path),
                    readOnly: readOnly)
            }
            // Never reuse a durable /dev/rbdN merely because the node exists:
            // kernel minors are reusable and may now identify another tenant's
            // image. Forget the stale coordinate without unmapping the device
            // that failed identity proof, then create a fresh mapping.
            try discardMapping(forKey: key)
        }

        // A timed-out map can already own a kernel device without returning
        // its path. Persist refusal before spawn, independently of credentials
        // and access mode, so restart or another mode cannot duplicate it.
        let marker = uncertainMappingMarker(for: attachment)
        guard !FileManager.default.fileExists(atPath: marker) else {
            throw KRBDMappingBlockedError(markerPath: marker)
        }
        try DurableFileWriter().write(Data(), to: marker, permissions: 0o600)
        var arguments = [
            "--conf", configPath,
            "--name", "client.\(user)",
            "--namespace", namespace,
            "map", "\(pool)/\(image)",
            "--options", "ms_mode=secure",
        ]
        if readOnly { arguments.append("--read-only") }
        let result: ProcessResult
        do {
            result = try await runCommand(URL(fileURLWithPath: rbdPath), arguments)
        } catch {
            if !SubprocessBudget.preserveStaging(after: error) {
                try? FileManager.default.removeItem(atPath: marker)
            }
            throw error
        }
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: marker)
            throw StorageBackendError.hostMisconfiguration(
                "rbd map exited with status \(result.terminationStatus)")
        }
        let path =
            String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.hasPrefix("/dev/rbd"), !path.contains("\n") else {
            throw StorageBackendError.hostMisconfiguration(
                "rbd map did not report a /dev/rbd block device")
        }
        mappings[key] = Mapping(path: path, references: 1)
        do {
            try persistMappings()
        } catch {
            mappings.removeValue(forKey: key)
            _ = try? await runCommand(
                URL(fileURLWithPath: rbdPath),
                ["unmap", path])
            throw StorageBackendError.hostMisconfiguration(
                "failed to persist the Firecracker krbd mapping inventory")
        }
        // The durable mapping inventory now owns this device. A cleanup error
        // must not discard its successful reference; a leftover refusal safely
        // blocks a future fresh map until operator review.
        try? FileManager.default.removeItem(atPath: marker)
        return FirecrackerRealizedDisk(
            canonical: attachment, realized: .blockDevice(path: path), readOnly: readOnly)
    }

    public func adopt(
        _ attachment: DiskAttachment, readOnly: Bool
    ) async throws -> FirecrackerRealizedDisk {
        guard case .rbd = attachment else {
            return FirecrackerRealizedDisk(
                canonical: attachment, realized: attachment, readOnly: readOnly)
        }
        let key = mappingKey(for: attachment, readOnly: readOnly)
        guard var mapping = mappings[key], deviceExists(mapping.path) else {
            throw StorageBackendError.hostMisconfiguration(
                "cannot re-adopt Firecracker RBD attachment: its durable krbd mapping is missing")
        }
        guard
            try await mappingMatches(
                path: mapping.path, attachment: attachment, readOnly: readOnly)
        else {
            try discardMapping(forKey: key)
            throw StorageBackendError.hostMisconfiguration(
                "cannot re-adopt Firecracker RBD attachment: its durable device identity no longer matches")
        }
        mapping.references += 1
        mappings[key] = mapping
        return FirecrackerRealizedDisk(
            canonical: attachment, realized: .blockDevice(path: mapping.path),
            readOnly: readOnly)
    }

    public func release(_ disk: FirecrackerRealizedDisk) async throws {
        guard case .rbd = disk.canonical else { return }
        let key = mappingKey(for: disk.canonical, readOnly: disk.readOnly)
        guard var mapping = mappings[key] else { return }
        if mapping.references > 1 {
            mapping.references -= 1
            mappings[key] = mapping
            return
        }
        guard deviceExists(mapping.path) else {
            try discardMapping(forKey: key)
            return
        }
        guard
            try await mappingMatches(
                path: mapping.path, attachment: disk.canonical, readOnly: disk.readOnly)
        else {
            // The minor was reused. It is safer to leak the no-longer-locatable
            // expected mapping than to unmap a different tenant's live disk.
            try discardMapping(forKey: key)
            throw StorageBackendError.hostMisconfiguration(
                "refusing to unmap a Firecracker RBD device whose live identity no longer matches")
        }
        let result = try await runCommand(
            URL(fileURLWithPath: rbdPath),
            ["unmap", mapping.path])
        guard result.terminationStatus == 0 else {
            // Keep both the in-memory and durable reference. Firecracker VM
            // deletion must fail and retry this exact unmap instead of
            // confirming deletion while the image remains mapped/open.
            throw StorageBackendError.hostMisconfiguration(
                "rbd unmap exited with status \(result.terminationStatus)")
        }
        try discardMapping(forKey: key)
    }

    private func mappingKey(for attachment: DiskAttachment, readOnly: Bool) -> String {
        guard
            case .rbd(
                let pool, let image, let namespace, _, _, let clusterId,
                let credentialId, _) = attachment
        else { return String(describing: attachment) }
        return [
            clusterId.uuidString.lowercased(), credentialId.uuidString.lowercased(),
            pool, namespace, image,
            readOnly ? "ro" : "rw",
        ].joined(separator: "/")
    }

    private func uncertainMappingMarker(for attachment: DiskAttachment) -> String {
        guard case .rbd(let pool, let image, let namespace, _, _, let clusterId, _, _) = attachment else {
            preconditionFailure("Only RBD attachments have mapping markers")
        }
        let coordinate = [clusterId.uuidString.lowercased(), pool, namespace, image].joined(separator: "/")
        let digest = SHA256.hash(data: Data(coordinate.utf8)).map { String(format: "%02x", $0) }.joined()
        return mappingStatePath + ".building-" + digest
    }

    private func persistMappings() throws {
        let persisted = mappings.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = entry.value.path
        }
        let data = try JSONEncoder().encode(persisted)
        try DurableFileWriter().write(data, to: mappingStatePath, permissions: 0o600)
    }

    private func discardMapping(forKey key: String) throws {
        guard let removed = mappings.removeValue(forKey: key) else { return }
        do {
            try persistMappings()
        } catch {
            mappings[key] = removed
            throw StorageBackendError.hostMisconfiguration(
                "failed to persist the Firecracker krbd mapping inventory")
        }
    }

    /// Proves that a durable block-device path still names this exact tenant
    /// image. `/dev/rbdN` alone is not an identity: N is recycled after unmap.
    private func mappingMatches(
        path: String, attachment: DiskAttachment, readOnly: Bool
    ) async throws -> Bool {
        guard
            case .rbd(
                let pool, let image, let namespace, let user, _, _, _, let configPath) = attachment,
            let deviceName = Self.deviceName(for: path)
        else { return false }

        let listing = try await runCommand(
            URL(fileURLWithPath: rbdPath),
            ["device", "list", "--format", "json", "--device-type", "krbd"])
        guard listing.terminationStatus == 0 else {
            throw StorageBackendError.hostMisconfiguration(
                "rbd device list failed while verifying a durable Firecracker mapping")
        }
        guard let devices = try? JSONDecoder().decode([MappedDevice].self, from: listing.standardOutput)
        else {
            throw StorageBackendError.hostMisconfiguration(
                "rbd device list returned malformed JSON while verifying a durable Firecracker mapping")
        }
        guard
            devices.contains(where: {
                $0.device == path && $0.pool == pool && ($0.namespace ?? "") == namespace
                    && $0.imageName == image
            })
        else { return false }

        let sysfsRoot = "/sys/class/block/\(deviceName)"
        let expectedFSID = try configuredFSID(at: configPath)
        let actualFSID: UUID
        let configInfo: String
        let readOnlyValue: String
        do {
            guard
                let parsed = UUID(
                    uuidString: try readTextFile("\(sysfsRoot)/device/cluster_fsid")
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            else { return false }
            actualFSID = parsed
            configInfo = try readTextFile("\(sysfsRoot)/device/config_info")
            readOnlyValue = try readTextFile("\(sysfsRoot)/ro")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw StorageBackendError.hostMisconfiguration(
                "could not read krbd sysfs identity while verifying a durable Firecracker mapping")
        }
        guard actualFSID == expectedFSID else { return false }

        // `config_info` may contain a legacy inline secret. Tokenize only the
        // non-secret facts we need and never propagate or log the raw string.
        let options = Set(
            configInfo.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        let expectedUser = user.hasPrefix("client.") ? String(user.dropFirst("client.".count)) : user
        guard
            options.contains("name=\(expectedUser)")
                || options.contains("name=client.\(expectedUser)"),
            options.contains("ms_mode=secure"),
            readOnlyValue == (readOnly ? "1" : "0")
        else { return false }
        return true
    }

    private func configuredFSID(at path: String) throws -> UUID {
        let config: String
        do {
            config = try readTextFile(path)
        } catch {
            throw StorageBackendError.hostMisconfiguration(
                "could not read the Ceph client configuration for krbd identity verification")
        }
        var section: String?
        for rawLine in config.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard section == "global", let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "fsid" else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let fsid = UUID(uuidString: value) { return fsid }
        }
        throw StorageBackendError.hostMisconfiguration(
            "Ceph client configuration has no valid global FSID for krbd identity verification")
    }

    private nonisolated static func deviceName(for path: String) -> String? {
        let prefix = "/dev/rbd"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = path.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return "rbd\(suffix)"
    }
    private func runCommand(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await runSubprocess(executable, arguments, .storage(executable: executable, arguments: arguments))
    }

}

struct KRBDMappingBlockedError: Error, LocalizedError, ClassifiableError {
    let markerPath: String
    var failureClassification: FailureClassification { .blocked }
    var errorDescription: String? {
        "Kernel RBD map completion is unknown (\(markerPath)). Confirm the map process stopped, inspect rbd device list, and verify/recover the exact cluster, pool, namespace, and image mapping before removing this marker and retrying; process exit alone does not remove a kernel mapping."
    }
}
