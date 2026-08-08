import Foundation
import StratoShared

/// Where a listener's view of the world came from.
///
/// The distinction exists for one question the listener cannot otherwise answer:
/// when nothing matches a caller's address, is that because this host does not
/// serve them, or because it does not yet know anything at all? The first is a
/// 404; the second must not be, because a 404 asserts knowledge the agent does
/// not have.
public enum MetadataSnapshotOrigin: String, Codable, Sendable, Equatable {
    /// Nothing is known: no sync has landed in this agent's lifetime and no
    /// durable record survived to be restored. Every read is a 503.
    case cold
    /// Restored from the agent's durable copy after a restart. Possibly stale —
    /// which is exactly the fail-static trade `MetadataStore` documents — but it
    /// is knowledge, so it answers.
    case restored
    /// A desired-state sync has been applied in this process.
    case live
}

/// One network's servable set, pushed from the agent to that network's listener.
///
/// This is the whole of the listener's input. It carries `InstanceMetadata`
/// verbatim rather than a narrowed projection because the downstream renderers
/// (STR-60, STR-65, STR-62) consume the rest of it, and a projection would have
/// to be widened by each of them in turn.
public struct MetadataSnapshot: Codable, Sendable, Equatable {
    public let networkId: UUID
    public let origin: MetadataSnapshotOrigin
    /// Everything servable on this network. Withdrawn instances are absent by
    /// construction — `MetadataStore.snapshot()` omits them — which is what
    /// stops a released VM's SSH keys reaching whoever next holds its address.
    public let instances: [InstanceMetadata]

    public init(networkId: UUID, origin: MetadataSnapshotOrigin, instances: [InstanceMetadata]) {
        self.networkId = networkId
        self.origin = origin
        self.instances = instances
    }

    /// The empty, knows-nothing snapshot a listener starts with before its first
    /// push. Not an empty `.live`: those differ by a 503 against a 404.
    public static func cold(networkId: UUID) -> MetadataSnapshot {
        MetadataSnapshot(networkId: networkId, origin: .cold, instances: [])
    }
}
