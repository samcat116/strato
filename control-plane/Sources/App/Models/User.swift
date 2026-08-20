import ControlPlanePostgres
import Fluent
import Foundation
import Vapor

/// Immutable account state. Persistence records are decoded privately by the
/// identity store and application code passes this value across concurrency
/// boundaries without Fluent identity-map or dirty-tracking semantics.
struct User: Content, Equatable, Sendable {
    static let schema = "users"

    let id: UUID?
    let username: String
    let email: String
    let displayName: String
    let currentOrganizationId: UUID?
    let isSystemAdmin: Bool
    let sourceRaw: String
    let oidcProviderID: UUID?
    let oidcSubject: String?
    let scimProvisioned: Bool
    let scimActive: Bool
    let sessionEpoch: Int
    let disabledAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        username: String,
        email: String,
        displayName: String,
        currentOrganizationId: UUID? = nil,
        isSystemAdmin: Bool = false,
        source: UserSource = .local,
        oidcProviderID: UUID? = nil,
        oidcSubject: String? = nil,
        scimProvisioned: Bool = false,
        scimActive: Bool = true,
        sessionEpoch: Int = 0,
        disabledAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.currentOrganizationId = currentOrganizationId
        self.isSystemAdmin = isSystemAdmin
        self.sourceRaw = source.rawValue
        self.oidcProviderID = oidcProviderID
        self.oidcSubject = oidcSubject
        self.scimProvisioned = scimProvisioned
        self.scimActive = scimActive
        self.sessionEpoch = sessionEpoch
        self.disabledAt = disabledAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: UserDirectorySnapshot) {
        self.init(
            id: snapshot.id,
            username: snapshot.username,
            email: snapshot.email,
            displayName: snapshot.displayName,
            currentOrganizationId: snapshot.currentOrganizationID,
            isSystemAdmin: snapshot.isSystemAdmin,
            source: UserSource(rawValue: snapshot.source) ?? .local,
            oidcProviderID: snapshot.oidcProviderID,
            oidcSubject: snapshot.oidcSubject,
            scimProvisioned: snapshot.scimProvisioned,
            scimActive: snapshot.scimActive,
            sessionEpoch: snapshot.sessionEpoch,
            disabledAt: snapshot.disabledAt,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    var directoryWrite: UserDirectoryWrite {
        UserDirectoryWrite(
            id: id ?? UUID(),
            username: username,
            email: email,
            displayName: displayName,
            currentOrganizationID: currentOrganizationId,
            isSystemAdmin: isSystemAdmin,
            source: sourceRaw,
            oidcProviderID: oidcProviderID,
            oidcSubject: oidcSubject,
            scimProvisioned: scimProvisioned,
            scimActive: scimActive,
            sessionEpoch: sessionEpoch,
            disabledAt: disabledAt
        )
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "User has no identifier") }
        return id
    }

    @discardableResult
    func persisted(on db: any Database) async throws -> Self {
        try await LegacyUserStore.upsert(self, on: db)
    }

    func save(on db: any Database) async throws {
        _ = try await persisted(on: db)
    }

    func delete(on db: any Database) async throws {
        guard let id else { return }
        _ = try await LegacyUserStore.delete(id: id, on: db)
    }

    static func find(_ id: UUID?, on db: any Database) async throws -> Self? {
        try await LegacyUserStore.user(id: id, on: db)
    }

    static func all(on db: any Database) async throws -> [Self] {
        try await LegacyUserStore.users(on: db)
    }

    static func count(on db: any Database) async throws -> Int {
        try await LegacyUserStore.count(on: db)
    }

    static func isFirstUser(on database: any Database) async throws -> Bool {
        try await count(on: database) == 0
    }

    static func findOIDCUser(
        subject: String,
        providerID: UUID,
        on database: any Database
    ) async throws -> User? {
        try await LegacyUserStore.users(
            oidcProviderID: providerID,
            oidcSubject: subject,
            on: database
        ).first
    }

    var source: UserSource { UserSource(rawValue: sourceRaw) ?? .local }

    var isOIDCAuthenticated: Bool { oidcSubject != nil && oidcProviderID != nil }

    func linkedToOIDCProvider(_ providerID: UUID, subject: String) -> Self {
        replacing(oidcProviderID: .some(providerID), oidcSubject: .some(subject))
    }

    func replacingCurrentOrganization(_ organizationID: UUID?) -> Self {
        replacing(currentOrganizationId: .some(organizationID))
    }

    func replacing(
        username: String? = nil,
        email: String? = nil,
        displayName: String? = nil,
        currentOrganizationId: UUID?? = nil,
        isSystemAdmin: Bool? = nil,
        source: UserSource? = nil,
        oidcProviderID: UUID?? = nil,
        oidcSubject: String?? = nil,
        scimProvisioned: Bool? = nil,
        scimActive: Bool? = nil,
        sessionEpoch: Int? = nil,
        disabledAt: Date?? = nil
    ) -> Self {
        Self(
            id: id,
            username: username ?? self.username,
            email: email ?? self.email,
            displayName: displayName ?? self.displayName,
            currentOrganizationId: currentOrganizationId ?? self.currentOrganizationId,
            isSystemAdmin: isSystemAdmin ?? self.isSystemAdmin,
            source: source ?? self.source,
            oidcProviderID: oidcProviderID ?? self.oidcProviderID,
            oidcSubject: oidcSubject ?? self.oidcSubject,
            scimProvisioned: scimProvisioned ?? self.scimProvisioned,
            scimActive: scimActive ?? self.scimActive,
            sessionEpoch: sessionEpoch ?? self.sessionEpoch,
            disabledAt: disabledAt ?? self.disabledAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension User: SessionAuthenticatable {
    var sessionID: UUID { id ?? UUID() }
}

struct UserSessionAuthenticator: AsyncSessionAuthenticator {
    typealias User = App.User
    let users: UserDirectoryPersistence

    func authenticate(sessionID: UUID, for request: Request) async throws {
        if let snapshot = try await users.user(id: sessionID) {
            request.auth.login(App.User(snapshot: snapshot))
        }
    }
}
