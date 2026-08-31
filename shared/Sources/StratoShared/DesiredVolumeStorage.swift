import Foundation

/// The Ceph messenger policy Strato permits for volume traffic.
///
/// Volume I/O crosses the site underlay rather than the agent's SPIFFE-authenticated
/// control channel. Keeping this as a closed enum, with no plaintext case, makes
/// the secure transport requirement part of the desired-state contract instead
/// of an agent-local default that different hosts could interpret differently.
public enum CephMessengerMode: String, Codable, Equatable, Sendable {
    case secure
}

/// Everything an agent needs to act as a client of one Ceph-backed volume.
///
/// `credentialId` is the stable identity of the scoped cephx credential. The
/// secret material itself is carried separately as `keyring`; agents use the
/// identity to replace that material atomically and to derive durable local and
/// libvirt references without treating the secret contents as an identifier.
public struct CephVolumeStorage: Codable, Equatable, Sendable {
    /// Strato's stable identity for the external or managed Ceph cluster.
    public let clusterId: UUID
    /// Ceph's own cluster identity, written into the generated `ceph.conf`.
    public let fsid: String
    /// RBD pool containing the image.
    public let pool: String
    /// Project-scoped RBD namespace. This is never shared across projects.
    public let namespace: String
    /// Scoped cephx identity, including its `client.` prefix.
    public let clientName: String
    /// Monitor endpoints in the form accepted by Ceph clients.
    public let monEndpoints: [String]
    /// Opaque version identity for this credential and its libvirt secret.
    /// Rotation mints a new id and permanently revokes the old one; callers
    /// must not assume this equals a project-access identity.
    public let credentialId: UUID
    /// Complete cephx keyring contents. This is secret material and must not be logged.
    public let keyring: String
    /// Messenger policy agents must write into their generated configuration.
    public let messengerMode: CephMessengerMode

    public init(
        clusterId: UUID,
        fsid: String,
        pool: String,
        namespace: String,
        clientName: String,
        monEndpoints: [String],
        credentialId: UUID,
        keyring: String,
        messengerMode: CephMessengerMode
    ) {
        self.clusterId = clusterId
        self.fsid = fsid
        self.pool = pool
        self.namespace = namespace
        self.clientName = clientName
        self.monEndpoints = monEndpoints
        self.credentialId = credentialId
        self.keyring = keyring
        self.messengerMode = messengerMode
    }
}

/// Backend-specific configuration for realizing a desired volume.
///
/// Local volumes intentionally carry no configuration: the receiving agent
/// owns their filesystem layout. Ceph volumes carry the complete client
/// configuration because any configured agent in the site may reconcile them.
public enum DesiredVolumeStorage: Codable, Equatable, Sendable {
    case local
    case ceph(CephVolumeStorage)

    private enum CodingKeys: String, CodingKey {
        case local
        case ceph
    }

    /// Gives the payload-free local case the same `{ "local": {} }` shape as
    /// Swift's synthesized enum representation while allowing the Ceph payload
    /// to stay flat instead of acquiring an implementation-detail `_0` key.
    private struct EmptyPayload: Codable {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "DesiredVolumeStorage must contain exactly one storage case"))
        }

        switch key {
        case .local:
            _ = try container.decode(EmptyPayload.self, forKey: .local)
            self = .local
        case .ceph:
            self = .ceph(try container.decode(CephVolumeStorage.self, forKey: .ceph))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(EmptyPayload(), forKey: .local)
        case .ceph(let configuration):
            try container.encode(configuration, forKey: .ceph)
        }
    }
}
