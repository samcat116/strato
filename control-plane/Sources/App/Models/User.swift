import Fluent
import Vapor
import Foundation

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "username")
    var username: String

    @Field(key: "email")
    var email: String

    @Field(key: "display_name")
    var displayName: String

    @OptionalField(key: "current_organization_id")
    var currentOrganizationId: UUID?

    @Field(key: "is_system_admin")
    var isSystemAdmin: Bool

    // OIDC linking fields
    @OptionalParent(key: "oidc_provider_id")
    var oidcProvider: OIDCProvider?

    @OptionalField(key: "oidc_subject")
    var oidcSubject: String? // The 'sub' claim from the OIDC provider

    // SCIM provisioning fields
    @Field(key: "scim_provisioned")
    var scimProvisioned: Bool

    @Field(key: "scim_active")
    var scimActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$user)
    var credentials: [UserCredential]

    // Organization relationships
    @Siblings(through: UserOrganization.self, from: \.$user, to: \.$organization)
    var organizations: [Organization]

    // Group relationships
    @Siblings(through: UserGroup.self, from: \.$user, to: \.$group)
    var groups: [Group]

    init() {}

    init(
        id: UUID? = nil,
        username: String,
        email: String,
        displayName: String,
        isSystemAdmin: Bool = false,
        oidcProviderID: UUID? = nil,
        oidcSubject: String? = nil,
        scimProvisioned: Bool = false,
        scimActive: Bool = true
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.isSystemAdmin = isSystemAdmin
        if let oidcProviderID = oidcProviderID {
            self.$oidcProvider.id = oidcProviderID
        }
        self.oidcSubject = oidcSubject
        self.scimProvisioned = scimProvisioned
        self.scimActive = scimActive
    }
}

extension User: Content {}

extension User: SessionAuthenticatable {
    var sessionID: UUID {
        return self.id ?? UUID()
    }
}

// MARK: - System Admin Helper Functions

extension User {
    /// Check if this is the first user being registered (no users exist in the database)
    static func isFirstUser(on database: Database) async throws -> Bool {
        let userCount = try await User.query(on: database).count()
        return userCount == 0
    }

    /// Check if any system admin exists in the database
    static func hasSystemAdmin(on database: Database) async throws -> Bool {
        let adminCount = try await User.query(on: database)
            .filter(\.$isSystemAdmin == true)
            .count()
        return adminCount > 0
    }

    /// Get the first system admin user
    static func getFirstSystemAdmin(on database: Database) async throws -> User? {
        return try await User.query(on: database)
            .filter(\.$isSystemAdmin == true)
            .first()
    }

    /// Find a user by OIDC subject and provider ID
    static func findOIDCUser(subject: String, providerID: UUID, on database: Database) async throws -> User? {
        return try await User.query(on: database)
            .filter(\.$oidcSubject == subject)
            .filter(\.$oidcProvider.$id == providerID)
            .first()
    }

    /// Get all groups this user belongs to within a specific organization
    func getGroupsInOrganization(_ organizationID: UUID, on db: Database) async throws -> [Group] {
        return try await self.$groups.query(on: db)
            .filter(\.$organization.$id, .equal, organizationID)
            .all()
    }

    /// Check if user belongs to a specific group
    func belongsToGroup(_ groupID: UUID, on db: Database) async throws -> Bool {
        let membership = try await UserGroup.query(on: db)
            .filter(\.$user.$id, .equal, self.id!)
            .filter(\.$group.$id, .equal, groupID)
            .first()

        return membership != nil
    }

    /// Check if user is authenticated via OIDC
    var isOIDCAuthenticated: Bool {
        return oidcSubject != nil && $oidcProvider.id != nil
    }

    /// Check if user is authenticated via Passkey
    func hasPasskeyCredentials(on db: Database) async throws -> Bool {
        let credentialCount = try await self.$credentials.query(on: db).count()
        return credentialCount > 0
    }

    /// Link user to an OIDC provider
    func linkToOIDCProvider(_ providerID: UUID, subject: String) {
        self.$oidcProvider.id = providerID
        self.oidcSubject = subject
    }

    /// Find user by OIDC subject and provider
    static func findByOIDCSubject(_ subject: String, providerID: UUID, on db: Database) async throws -> User? {
        return try await User.query(on: db)
            .filter(\.$oidcSubject == subject)
            .filter(\.$oidcProvider.$id == providerID)
            .first()
    }
}

// MARK: - UserCredential Model for Passkeys

final class UserCredential: Model, @unchecked Sendable {
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
    var transportsJSON: String

    // Computed property for array access
    var transports: [String] {
        get {
            guard let data = transportsJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else {
                transportsJSON = "[]"
                return
            }
            transportsJSON = string
        }
    }

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

final class AuthenticationChallenge: Model, @unchecked Sendable {
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
