import Fluent
import Foundation

/// An append-only tombstone for one retired project cephx credential.
///
/// `clusterID` deliberately is not a foreign key: deleting an external-cluster
/// registration must not erase the instruction from agents that can re-enroll
/// later with stale local state. `siteID` is the durable routing scope; deleting
/// the site removes its agents and is the only lifecycle boundary for rows.
final class CephCredentialRevocation: Model, @unchecked Sendable {
    static let schema = "ceph_credential_revocations"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "site_id")
    var site: Site

    @Field(key: "cluster_id")
    var clusterID: UUID

    @Field(key: "credential_id")
    var credentialID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        siteID: UUID,
        clusterID: UUID,
        credentialID: UUID
    ) {
        self.id = id
        self.$site.id = siteID
        self.clusterID = clusterID
        self.credentialID = credentialID
    }
}
