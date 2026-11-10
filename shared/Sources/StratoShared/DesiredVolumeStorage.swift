import Foundation
import SwiftProtobuf

/// The Ceph messenger policy Strato permits for volume traffic.
///
/// Volume I/O crosses the site underlay rather than the agent's SPIFFE-authenticated
/// control channel. Keeping this as a closed enum, with no plaintext case, makes
/// the secure transport requirement part of the desired-state contract instead
/// of an agent-local default that different hosts could interpret differently.
public typealias CephMessengerMode = Strato_Agent_V1_CephMessengerMode
extension Strato_Agent_V1_CephMessengerMode: Codable {

    public var protocolValue: String {
        switch self {
        case .secure: return "secure"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "secure": self = .secure
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Everything an agent needs to act as a client of one Ceph-backed volume.
///
/// `credentialId` is the stable identity of the scoped cephx credential. The
/// secret material itself is carried separately as `keyring`; agents use the
/// identity to replace that material atomically and to derive durable local and
/// libvirt references without treating the secret contents as an identifier.
public typealias CephVolumeStorage = Strato_Agent_V1_CephVolumeStorage
extension Strato_Agent_V1_CephVolumeStorage: Codable {
    /// RBD images are named from their Strato volume identity. Both sides of
    /// the reconciliation boundary use this helper so an observation cannot
    /// redirect a volume row to another image in the same project namespace.
    public static let imagePrefix = "strato-volume-"
    public static let defaultClientRoot = "/var/lib/strato/ceph"

    public static func imageName(volumeId: UUID) -> String {
        imagePrefix + volumeId.uuidString.lowercased()
    }

    public static func clientDirectory(
        root: String = defaultClientRoot, clusterId: UUID, credentialId: UUID
    ) -> String {
        "\(root)/\(clusterId.uuidString.lowercased())/\(credentialId.uuidString.lowercased())"
    }

    public static func configPath(
        root: String = defaultClientRoot, clusterId: UUID, credentialId: UUID
    ) -> String {
        "\(clientDirectory(root: root, clusterId: clusterId, credentialId: credentialId))/ceph.conf"
    }

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
        self.init()
        self._jsonClusterId = clusterId
        self._jsonFsid = fsid
        self._jsonPool = pool
        self._jsonNamespace = namespace
        self._jsonClientName = clientName
        self._jsonMonEndpoints = monEndpoints
        self._jsonCredentialId = credentialId
        self._jsonKeyring = keyring
        self._jsonMessengerMode = messengerMode
    }

    private enum CodingKeys: String, CodingKey {
        case clusterId; case fsid; case pool; case namespace; case clientName; case monEndpoints; case credentialId;
        case keyring; case messengerMode
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonClusterId = try container.decode(UUID.self, forKey: .clusterId)
        self._jsonFsid = try container.decode(String.self, forKey: .fsid)
        self._jsonPool = try container.decode(String.self, forKey: .pool)
        self._jsonNamespace = try container.decode(String.self, forKey: .namespace)
        self._jsonClientName = try container.decode(String.self, forKey: .clientName)
        self._jsonMonEndpoints = try container.decode([String].self, forKey: .monEndpoints)
        self._jsonCredentialId = try container.decode(UUID.self, forKey: .credentialId)
        self._jsonKeyring = try container.decode(String.self, forKey: .keyring)
        self._jsonMessengerMode = try container.decode(CephMessengerMode.self, forKey: .messengerMode)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonClusterId, forKey: .clusterId)
        try container.encode(_jsonFsid, forKey: .fsid)
        try container.encode(_jsonPool, forKey: .pool)
        try container.encode(_jsonNamespace, forKey: .namespace)
        try container.encode(_jsonClientName, forKey: .clientName)
        try container.encode(_jsonMonEndpoints, forKey: .monEndpoints)
        try container.encode(_jsonCredentialId, forKey: .credentialId)
        try container.encode(_jsonKeyring, forKey: .keyring)
        try container.encode(_jsonMessengerMode, forKey: .messengerMode)
    }

}

/// Backend-specific configuration for realizing a desired volume.
///
/// Local volumes intentionally carry no configuration: the receiving agent
/// owns their filesystem layout. Ceph volumes carry the complete client
/// configuration because any configured agent in the site may reconcile them.
public typealias DesiredVolumeStorage = Strato_Agent_V1_DesiredVolumeStorage
