import Foundation

public enum CephCredentialRevocationError: Error, LocalizedError, Sendable {
    case stillReferenced(clusterId: UUID, credentialId: UUID)
    case localCleanupFailed
    case libvirtSecretCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .stillReferenced(let clusterId, let credentialId):
            return
                "Ceph credential \(credentialId.uuidString) in cluster \(clusterId.uuidString) is still referenced by desired state"
        case .localCleanupFailed:
            return "Ceph credential files could not be removed"
        case .libvirtSecretCleanupFailed:
            return "Ceph libvirt secret could not be undefined"
        }
    }
}

/// Removes one revoked Ceph client identity from this host.
///
/// A durable, non-secret `libvirt-secret.xml` file records that QEMU secret
/// installation may have reached libvirt. Firecracker-only clients never
/// create it, so their revocation does not require virsh. Sensitive files are
/// erased before an attempted `secret-undefine`; if that command fails, the
/// marker remains and the permanent desired-state tombstone retries it on the
/// next sync.
public actor CephCredentialRevoker {
    private let clientRoot: String
    private let virshPath: String
    private let runSubprocess: SubprocessRunner

    public init(
        clientRoot: String = CephRBDStorageBackend.defaultClientRoot,
        virshPath: String = CephRBDStorageBackend.defaultVirshPath,
        runSubprocess: @escaping SubprocessRunner = {
            try await ProcessRunner.run(executableURL: $0, arguments: $1)
        }
    ) {
        self.clientRoot = clientRoot
        self.virshPath = virshPath
        self.runSubprocess = runSubprocess
    }

    public func revoke(clusterId: UUID, credentialId: UUID) async throws {
        let directory = try credentialDirectory(clusterId: clusterId, credentialId: credentialId)
        guard FileManager.default.fileExists(atPath: directory) else { return }

        let secretMarker = (directory as NSString).appendingPathComponent("libvirt-secret.xml")
        let sensitiveFiles = [
            CephRBDStorageBackend.configPath(
                root: clientRoot, clusterId: clusterId, credentialId: credentialId),
            CephRBDStorageBackend.keyringPath(
                root: clientRoot, clusterId: clusterId, credentialId: credentialId),
            (directory as NSString).appendingPathComponent("libvirt-secret.value"),
        ]

        // Try every sensitive path even if one removal fails. Nothing about a
        // filesystem error should leave a different secret behind merely due
        // to loop order.
        var sensitiveCleanupFailed = false
        for path in sensitiveFiles {
            do {
                try Self.removeIfPresent(path)
            } catch {
                sensitiveCleanupFailed = true
            }
        }
        guard !sensitiveCleanupFailed else {
            throw CephCredentialRevocationError.localCleanupFailed
        }

        if FileManager.default.fileExists(atPath: secretMarker) {
            let result: ProcessResult
            do {
                result = try await runSubprocess(
                    URL(fileURLWithPath: virshPath),
                    ["secret-undefine", credentialId.uuidString.lowercased()])
            } catch {
                throw CephCredentialRevocationError.libvirtSecretCleanupFailed
            }
            guard result.terminationStatus == 0 || Self.isMissingSecret(result) else {
                // Subprocess output can contain arbitrary host data and is
                // deliberately not included in the surfaced error.
                throw CephCredentialRevocationError.libvirtSecretCleanupFailed
            }
            // The marker is the retry token: retain it only while libvirt
            // cleanup is unconfirmed. Once undefine succeeds (or proves the
            // secret already absent), remove it explicitly before deleting the
            // now-empty credential directory.
            do {
                try Self.removeIfPresent(secretMarker)
            } catch {
                throw CephCredentialRevocationError.localCleanupFailed
            }
        }

        do {
            try Self.removeIfPresent(directory)
        } catch {
            throw CephCredentialRevocationError.localCleanupFailed
        }
    }

    private func credentialDirectory(clusterId: UUID, credentialId: UUID) throws -> String {
        let root = URL(fileURLWithPath: clientRoot, isDirectory: true).standardizedFileURL
        let cluster = root.appendingPathComponent(
            clusterId.uuidString.lowercased(), isDirectory: true)
        let credential = cluster.appendingPathComponent(
            credentialId.uuidString.lowercased(), isDirectory: true)

        // The targets above are UUID path components, but retain an explicit
        // containment proof at the destructive boundary so a future layout
        // refactor cannot widen this into a cluster- or root-level removal.
        guard cluster.deletingLastPathComponent().standardizedFileURL == root,
            credential.deletingLastPathComponent().standardizedFileURL == cluster.standardizedFileURL
        else {
            throw CephCredentialRevocationError.localCleanupFailed
        }
        return credential.path
    }

    private nonisolated static func removeIfPresent(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private nonisolated static func isMissingSecret(_ result: ProcessResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("no secret with matching uuid")
            || output.contains("secret not found")
            || output.contains("failed to get secret")
    }
}
