import Fluent
import Foundation

/// Why a recoverable encrypted value exists. The purpose is metadata only; the
/// value is never returned by an API response.
enum StoredSecretPurpose: String, Codable, CaseIterable, Sendable {
    case cephClusterObserverKeyring = "ceph_cluster_observer_keyring"
    case cephProjectKeyring = "ceph_project_keyring"
}

/// Generic indirection for durable recoverable secrets. Callers must encrypt
/// `encryptedValue` through `SecretsEncryptionService` before saving it.
final class StoredSecret: Model, @unchecked Sendable {
    static let schema = "stored_secrets"

    @ID(key: .id)
    var id: UUID?

    @Enum(key: "purpose")
    var purpose: StoredSecretPurpose

    @Field(key: "encrypted_value")
    var encryptedValue: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        purpose: StoredSecretPurpose,
        encryptedValue: String
    ) {
        self.id = id
        self.purpose = purpose
        self.encryptedValue = encryptedValue
    }
}
