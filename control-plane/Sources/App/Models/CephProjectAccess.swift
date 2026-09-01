import Fluent
import Foundation
import Vapor

/// One project's scoped cephx identity for a site cluster. Namespace and RBD
/// pool selection live on `StoragePool`; this row owns only credentials.
final class CephProjectAccess: Model, @unchecked Sendable {
    static let schema = "ceph_project_accesses"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "cluster_id")
    var cluster: CephCluster

    @Parent(key: "project_id")
    var project: Project

    @Field(key: "client_name")
    var clientName: String

    @Parent(key: "keyring_secret_ref")
    var keyringSecret: StoredSecret

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clusterID: UUID,
        projectID: UUID,
        clientName: String,
        keyringSecretRef: UUID
    ) {
        self.id = id
        self.$cluster.id = clusterID
        self.$project.id = projectID
        self.clientName = clientName
        self.$keyringSecret.id = keyringSecretRef
    }
}

struct CephProjectAccessResponse: Content {
    let id: UUID?
    let clusterId: UUID
    let projectId: UUID
    let clientName: String
    let hasCredential: Bool
    let storagePool: StoragePoolResponse
    let createdAt: Date?
    let updatedAt: Date?

    init(from access: CephProjectAccess, pool: StoragePool) {
        id = access.id
        clusterId = access.$cluster.id
        projectId = access.$project.id
        clientName = access.clientName
        hasCredential = true
        storagePool = StoragePoolResponse(from: pool)
        createdAt = access.createdAt
        updatedAt = access.updatedAt
    }
}
