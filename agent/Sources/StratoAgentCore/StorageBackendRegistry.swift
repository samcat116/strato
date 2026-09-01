import Foundation
import StratoShared

public enum StorageBackendRegistryError: Error, LocalizedError, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Storage backend unavailable: \(reason)"
        }
    }
}

/// The one selection point for storage drivers.
///
/// Agent reconciliation asks this registry for the backend named by desired
/// state. Concrete backend switches do not spread into volume, snapshot, or VM
/// paths. Ceph clients are cached per cluster/project credential and replaced
/// atomically when any connection or keyring material rotates.
public actor StorageBackendRegistry {
    public typealias CephFactory = @Sendable (CephVolumeStorage) -> any CephStorageBackend

    private struct CredentialIdentity: Hashable {
        let clusterId: UUID
        let credentialId: UUID
    }

    private struct CephCacheKey: Hashable {
        let clusterId: UUID
        let pool: String
        let namespace: String
        let credentialId: UUID
    }

    private struct CephCacheEntry {
        let configuration: CephVolumeStorage
        let backend: any CephStorageBackend
    }

    private let local: any StorageBackend
    private let makeCeph: CephFactory
    private let credentialRevoker: CephCredentialRevoker
    private var cephBackends: [CephCacheKey: CephCacheEntry] = [:]
    private var revokedCredentials: Set<CredentialIdentity> = []

    public init(
        local: any StorageBackend,
        makeCeph: @escaping CephFactory,
        credentialRevoker: CephCredentialRevoker = CephCredentialRevoker()
    ) {
        self.local = local
        self.makeCeph = makeCeph
        self.credentialRevoker = credentialRevoker
    }

    public func backend(for storage: DesiredVolumeStorage) throws -> any StorageBackend {
        switch storage {
        case .local:
            return local
        case .ceph(let configuration):
            let identity = CredentialIdentity(
                clusterId: configuration.clusterId,
                credentialId: configuration.credentialId)
            guard !revokedCredentials.contains(identity) else {
                throw StorageBackendRegistryError.unavailable(
                    "the Ceph credential has been permanently revoked on this agent")
            }
            let key = CephCacheKey(
                clusterId: configuration.clusterId,
                pool: configuration.pool,
                namespace: configuration.namespace,
                credentialId: configuration.credentialId)
            if let cached = cephBackends[key], cached.configuration == configuration {
                return cached.backend
            }
            let backend = makeCeph(configuration)
            cephBackends[key] = CephCacheEntry(configuration: configuration, backend: backend)
            return backend
        }
    }

    public func backend(for volume: DesiredVolumeState) throws -> any StorageBackend {
        try backend(for: volume.storage)
    }

    public func localInventory() async throws -> [String: DiskAttachment] {
        try await local.listVolumes()
    }

    /// Applies one permanent credential tombstone after proving this sync no
    /// longer asks the agent to use it. Cache eviction happens before cleanup,
    /// so even a failed cleanup cannot leave a prepared backend available to
    /// recreate deleted key material; the next desired sync retries cleanup.
    public func revokeCephCredential(
        clusterId: UUID,
        credentialId: UUID,
        activeStorages: [DesiredVolumeStorage],
        activeAttachments: [DiskAttachment]
    ) async throws {
        guard
            !Self.referencesCredential(
                clusterId: clusterId, credentialId: credentialId,
                storages: activeStorages, attachments: activeAttachments)
        else {
            throw CephCredentialRevocationError.stillReferenced(
                clusterId: clusterId, credentialId: credentialId)
        }

        let identity = CredentialIdentity(clusterId: clusterId, credentialId: credentialId)
        let revokedKeys = cephBackends.keys.filter {
            $0.clusterId == clusterId && $0.credentialId == credentialId
        }
        let revokedBackends = revokedKeys.compactMap {
            cephBackends.removeValue(forKey: $0)?.backend
        }
        // This mutation deliberately precedes every await below. A concurrent
        // reconcile can neither retrieve the old cached actor nor construct a
        // replacement once the permanent tombstone has reached this registry.
        revokedCredentials.insert(identity)
        for backend in revokedBackends {
            await backend.invalidateForCredentialRevocation()
        }
        try await credentialRevoker.revoke(clusterId: clusterId, credentialId: credentialId)
    }

    public nonisolated static func referencesCredential(
        clusterId: UUID,
        credentialId: UUID,
        storages: [DesiredVolumeStorage],
        attachments: [DiskAttachment]
    ) -> Bool {
        storages.contains { storage in
            guard case .ceph(let configuration) = storage else { return false }
            return configuration.clusterId == clusterId
                && configuration.credentialId == credentialId
        }
            || attachments.contains { attachment in
                guard
                    case .rbd(_, _, _, _, _, let attachmentClusterId, let attachmentCredentialId, _) =
                        attachment
                else { return false }
                return attachmentClusterId == clusterId && attachmentCredentialId == credentialId
            }
    }

    /// Local bytes are enumerated because they are host ownership. Ceph images
    /// are inspected only by desired volume id because a namespace-wide `ls`
    /// is cluster state and must never be reported as this host's inventory.
    public func inventory(
        desiredVolumes: [DesiredVolumeState]
    ) async throws -> [String: DiskAttachment] {
        var inventory = try await local.listVolumes()
        for desired in desiredVolumes {
            guard case .ceph = desired.storage else { continue }
            let id = desired.volumeId.uuidString
            let selected = try backend(for: desired.storage)
            if let attachment = try await selected.inspectVolume(volumeId: id) {
                inventory[id] = attachment
            }
        }
        return inventory
    }
}
