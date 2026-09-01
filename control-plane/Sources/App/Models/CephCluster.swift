import Fluent
import Foundation
import Vapor

enum CephClusterHealth: String, Codable, CaseIterable, Sendable {
    case unknown
    case ok
    case warning
    case error
}

/// A site's existing Ceph cluster. STR-155 registers external clusters only;
/// `managed` is persisted now so later cephadm orchestration has an honest
/// ownership boundary.
final class CephCluster: Model, @unchecked Sendable {
    static let schema = "ceph_clusters"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "site_id")
    var site: Site

    @Field(key: "fsid")
    var fsid: String

    @Field(key: "managed")
    var managed: Bool

    @Field(key: "mon_endpoints")
    var monEndpoints: [String]

    /// Observer identity used for cluster health and capacity probes. Tenant
    /// volume I/O uses the project-specific identity below instead.
    @Field(key: "client_name")
    var clientName: String

    @Parent(key: "keyring_secret_ref")
    var keyringSecret: StoredSecret

    @Enum(key: "health")
    var health: CephClusterHealth

    @OptionalField(key: "capacity_bytes")
    var capacityBytes: Int64?

    @OptionalField(key: "used_bytes")
    var usedBytes: Int64?

    @OptionalField(key: "observed_at")
    var observedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        siteID: UUID,
        fsid: String,
        managed: Bool = false,
        monEndpoints: [String],
        clientName: String,
        keyringSecretRef: UUID,
        health: CephClusterHealth = .unknown,
        capacityBytes: Int64? = nil,
        usedBytes: Int64? = nil,
        observedAt: Date? = nil
    ) {
        self.id = id
        self.$site.id = siteID
        self.fsid = fsid
        self.managed = managed
        self.monEndpoints = monEndpoints
        self.clientName = clientName
        self.$keyringSecret.id = keyringSecretRef
        self.health = health
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.observedAt = observedAt
    }
}

struct CephClusterResponse: Content {
    let id: UUID?
    let siteId: UUID
    let fsid: String
    let managed: Bool
    let monEndpoints: [String]
    let clientName: String
    let hasCredential: Bool
    let health: CephClusterHealth
    let capacityBytes: Int64?
    let usedBytes: Int64?
    let observedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    init(from cluster: CephCluster) {
        id = cluster.id
        siteId = cluster.$site.id
        fsid = cluster.fsid
        managed = cluster.managed
        monEndpoints = cluster.monEndpoints
        clientName = cluster.clientName
        hasCredential = true
        health = cluster.health
        capacityBytes = cluster.capacityBytes
        usedBytes = cluster.usedBytes
        observedAt = cluster.observedAt
        createdAt = cluster.createdAt
        updatedAt = cluster.updatedAt
    }
}
