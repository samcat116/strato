import Fluent
import Vapor
import Foundation

final class User: Model {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "username")
    var username: String

    @Field(key: "email")
    var email: String

    @Field(key: "display_name")
    var displayName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$user)
    var credentials: [UserCredential]

    init() {}

    init(
        id: UUID? = nil,
        username: String,
        email: String,
        displayName: String
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
    }
}

extension User: Content {}

extension User: SessionAuthenticatable {
    var sessionID: UUID {
        return self.id ?? UUID()
    }
}

// MARK: - UserCredential Model for Passkeys

final class UserCredential: Model {
    static let schema = "user_credentials"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "credential_id")
    var credentialID: Data

    @Field(key: "public_key")
    var publicKey: Data

    @Field(key: "sign_count")
    var signCount: Int32

    @Field(key: "transports")
    var transports: [String]

    @Field(key: "backup_eligible")
    var backupEligible: Bool

    @Field(key: "backup_state")
    var backupState: Bool

    @Field(key: "device_type")
    var deviceType: String

    @Field(key: "name")
    var name: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "last_used_at", on: .none)
    var lastUsedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        credentialID: Data,
        publicKey: Data,
        signCount: Int32 = 0,
        transports: [String] = [],
        backupEligible: Bool = false,
        backupState: Bool = false,
        deviceType: String = "unknown",
        name: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = signCount
        self.transports = transports
        self.backupEligible = backupEligible
        self.backupState = backupState
        self.deviceType = deviceType
        self.name = name
    }
}

extension UserCredential: Content {}

// MARK: - Challenge Storage

final class AuthenticationChallenge: Model {
    static let schema = "authentication_challenges"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "challenge")
    var challenge: String

    @Field(key: "user_id")
    var userID: UUID?

    @Field(key: "operation")
    var operation: String // "registration" or "authentication"

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        challenge: String,
        userID: UUID? = nil,
        operation: String
    ) {
        self.id = id
        self.challenge = challenge
        self.userID = userID
        self.operation = operation
        self.expiresAt = Date().addingTimeInterval(300) // 5 minutes
    }
}

extension AuthenticationChallenge: Content {}