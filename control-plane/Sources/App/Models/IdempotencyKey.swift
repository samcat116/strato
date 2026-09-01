import Fluent
import Foundation

/// A short-lived claim that one principal has already submitted one HTTP
/// mutation. Unlike `ResourceEvent`, these rows are deliberately swept after
/// their replay window; the audit record remains append-only and permanent.
final class IdempotencyKey: Model, @unchecked Sendable {
    static let schema = "idempotency_keys"

    @ID(key: .id)
    var id: UUID?

    @Enum(key: "principal_type")
    var principalType: MutationActorType

    @OptionalField(key: "principal_id")
    var principalID: UUID?

    @Field(key: "key")
    var key: String

    @Field(key: "request_digest")
    var requestDigest: Data

    @OptionalEnum(key: "resource_kind")
    var resourceKind: OperationResourceKind?

    @OptionalField(key: "resource_id")
    var resourceID: UUID?

    @OptionalField(key: "mutation_id")
    var mutationID: UUID?

    @OptionalField(key: "target_generation")
    var targetGeneration: Int64?

    @OptionalField(key: "response_status")
    var responseStatus: Int?

    @OptionalField(key: "response_body")
    var responseBody: Data?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(
        id: UUID = UUID(),
        actor: MutationActor,
        key: String,
        requestDigest: Data,
        resourceKind: OperationResourceKind? = nil,
        resourceID: UUID? = nil,
        mutationID: UUID? = nil,
        targetGeneration: Int64? = nil,
        responseStatus: Int? = nil,
        responseBody: Data? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.principalType = actor.type
        self.principalID = actor.id
        self.key = key
        self.requestDigest = requestDigest
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.mutationID = mutationID
        self.targetGeneration = targetGeneration
        self.responseStatus = responseStatus
        self.responseBody = responseBody
        self.expiresAt = expiresAt
    }
}
