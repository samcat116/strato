import Foundation
import PostgresNIO

public struct OIDCGroupMappingValue: Codable, Equatable, Sendable {
    public let claimValue: String
    public let groupID: UUID

    public init(claimValue: String, groupID: UUID) {
        self.claimValue = claimValue
        self.groupID = groupID
    }
}

public struct OIDCRoleMappingValue: Codable, Equatable, Sendable {
    public let claimValue: String
    public let roleID: UUID

    public init(claimValue: String, roleID: UUID) {
        self.claimValue = claimValue
        self.roleID = roleID
    }
}

/// Complete provider state accepted by create and replacement operations.
/// Callers build a new value for every mutation; no database-backed object is
/// retained or mutated across an async boundary.
public struct OIDCProviderWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let clientID: String
    public let encryptedClientSecret: String
    public let discoveryURL: String?
    public let issuer: String?
    public let authorizationEndpoint: String?
    public let tokenEndpoint: String?
    public let userinfoEndpoint: String?
    public let jwksURI: String?
    public let endSessionEndpoint: String?
    public let discoveredHosts: [String]
    public let scopes: [String]
    public let enabled: Bool
    public let useNonce: Bool
    public let groupsClaim: String?
    public let groupMappings: [OIDCGroupMappingValue]
    public let adminClaimValues: [String]
    public let roleMappings: [OIDCRoleMappingValue]
    public let defaultRoleID: UUID?

    public init(
        id: UUID = UUID(),
        organizationID: UUID,
        name: String,
        clientID: String,
        encryptedClientSecret: String,
        discoveryURL: String? = nil,
        issuer: String? = nil,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        userinfoEndpoint: String? = nil,
        jwksURI: String? = nil,
        endSessionEndpoint: String? = nil,
        discoveredHosts: [String] = [],
        scopes: [String] = ["openid", "profile", "email"],
        enabled: Bool = true,
        useNonce: Bool = true,
        groupsClaim: String? = nil,
        groupMappings: [OIDCGroupMappingValue] = [],
        adminClaimValues: [String] = [],
        roleMappings: [OIDCRoleMappingValue] = [],
        defaultRoleID: UUID? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.clientID = clientID
        self.encryptedClientSecret = encryptedClientSecret
        self.discoveryURL = discoveryURL
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.jwksURI = jwksURI
        self.endSessionEndpoint = endSessionEndpoint
        self.discoveredHosts = discoveredHosts
        self.scopes = scopes
        self.enabled = enabled
        self.useNonce = useNonce
        self.groupsClaim = groupsClaim
        self.groupMappings = groupMappings
        self.adminClaimValues = adminClaimValues
        self.roleMappings = roleMappings
        self.defaultRoleID = defaultRoleID
    }
}

public struct OIDCProviderSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let clientID: String
    public let encryptedClientSecret: String
    public let discoveryURL: String?
    public let issuer: String?
    public let authorizationEndpoint: String?
    public let tokenEndpoint: String?
    public let userinfoEndpoint: String?
    public let jwksURI: String?
    public let endSessionEndpoint: String?
    public let discoveredHosts: [String]
    public let scopes: [String]
    public let enabled: Bool
    public let useNonce: Bool
    public let groupsClaim: String?
    public let groupMappings: [OIDCGroupMappingValue]
    public let adminClaimValues: [String]
    public let roleMappings: [OIDCRoleMappingValue]
    public let defaultRoleID: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var discoveredHostSet: Set<String> {
        Set(discoveredHosts.map { $0.lowercased() })
    }

    public var hasRequiredEndpoints: Bool {
        authorizationEndpoint != nil && tokenEndpoint != nil && jwksURI != nil
    }

    public func authorizationURL(
        redirectURI: String,
        state: String,
        nonce: String?,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil
    ) -> String? {
        guard let authorizationEndpoint else { return nil }
        var components = URLComponents(string: authorizationEndpoint)
        var queryItems = components?.queryItems ?? []
        queryItems += [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        if let nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }
        if let codeChallenge, let codeChallengeMethod {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod))
        }
        components?.queryItems = queryItems
        return components?.url?.absoluteString
    }

    public func endSessionURL(idTokenHint: String?, postLogoutRedirectURI: String?) -> String? {
        guard let endSessionEndpoint else { return nil }
        var components = URLComponents(string: endSessionEndpoint)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        if let idTokenHint {
            queryItems.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
        }
        if let postLogoutRedirectURI {
            queryItems.append(URLQueryItem(name: "post_logout_redirect_uri", value: postLogoutRedirectURI))
        }
        components?.queryItems = queryItems
        return components?.url?.absoluteString
    }
}

public enum OIDCProviderDeleteResult: Equatable, Sendable {
    case deleted(UUID)
    case inUse(linkedUsers: Int)
    case notFound
}

public enum OIDCProviderPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns provider configuration, discovery state, and stored client secrets.
public struct OIDCProvidersPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func providers(organizationID: UUID, enabledOnly: Bool = false) async throws
        -> [OIDCProviderSnapshot]
    {
        try await database.withSession(operation: "oidc_providers.list") { session in
            let rows = if enabledOnly {
                try await session.execute(
                    ListEnabledOIDCProviders(organizationID: organizationID),
                    operation: "oidc_providers.list_enabled.query"
                )
            } else {
                try await session.execute(
                    ListOIDCProviders(organizationID: organizationID),
                    operation: "oidc_providers.list.query"
                )
            }
            return rows.map(\.snapshot)
        }
    }

    public func provider(id: UUID) async throws -> OIDCProviderSnapshot? {
        try await database.withSession(operation: "oidc_providers.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindOIDCProvider(id: id),
                    operation: "oidc_providers.lookup.query"
                )
            )
        }
    }

    public func ownedProvider(id: UUID, organizationID: UUID) async throws -> OIDCProviderSnapshot? {
        try await database.withSession(operation: "oidc_providers.lookup_owned") { session in
            try oneOrNone(
                await session.execute(
                    FindOwnedOIDCProvider(id: id, organizationID: organizationID),
                    operation: "oidc_providers.lookup_owned.query"
                )
            )
        }
    }

    public func providerNamed(_ name: String, organizationID: UUID) async throws -> OIDCProviderSnapshot? {
        try await database.withSession(operation: "oidc_providers.lookup_named") { session in
            try oneOrNone(
                await session.execute(
                    FindNamedOIDCProvider(name: name, organizationID: organizationID),
                    operation: "oidc_providers.lookup_named.query"
                )
            )
        }
    }

    public func count(organizationID: UUID) async throws -> Int {
        try await database.withSession(operation: "oidc_providers.count") { session in
            let rows = try await session.execute(
                CountOIDCProviders(organizationID: organizationID),
                operation: "oidc_providers.count.query"
            )
            guard rows.count == 1, let count = rows.first else {
                throw OIDCProviderPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return Int(count)
        }
    }

    public func create(_ write: OIDCProviderWrite) async throws -> OIDCProviderSnapshot {
        try await database.withSession(operation: "oidc_providers.create") { session in
            try only(
                await session.execute(
                    InsertOIDCProvider(write: write),
                    operation: "oidc_providers.create.query"
                )
            )
        }
    }

    /// Replaces the complete mutable configuration while retaining database-owned timestamps.
    public func replace(_ write: OIDCProviderWrite) async throws -> OIDCProviderSnapshot? {
        try await database.withSession(operation: "oidc_providers.replace") { session in
            try oneOrNone(
                await session.execute(
                    ReplaceOIDCProvider(write: write),
                    operation: "oidc_providers.replace.query"
                )
            )
        }
    }

    /// Locks the provider before checking for linked users so a concurrent link
    /// cannot be silently cleared by the schema's ON DELETE SET NULL action.
    public func deleteIfUnused(id: UUID, organizationID: UUID) async throws -> OIDCProviderDeleteResult {
        try await database.withTransaction(operation: "oidc_providers.delete_if_unused") { session in
            let locked = try await session.execute(
                LockOwnedOIDCProvider(id: id, organizationID: organizationID),
                operation: "oidc_providers.delete_if_unused.lock"
            )
            guard locked.count == 1 else { return .notFound }

            let counts = try await session.execute(
                CountLinkedOIDCUsers(providerID: id),
                operation: "oidc_providers.delete_if_unused.count_users"
            )
            guard counts.count == 1, let linkedUsers = counts.first else {
                throw OIDCProviderPersistenceError.unexpectedRowCount(expected: 1, actual: counts.count)
            }
            guard linkedUsers == 0 else { return .inUse(linkedUsers: Int(linkedUsers)) }

            let deleted = try await session.execute(
                DeleteOwnedOIDCProvider(id: id, organizationID: organizationID),
                operation: "oidc_providers.delete_if_unused.delete"
            )
            guard deleted.count == 1, let deletedID = deleted.first else {
                throw OIDCProviderPersistenceError.unexpectedRowCount(expected: 1, actual: deleted.count)
            }
            return .deleted(deletedID)
        }
    }

    public func providersWithClientSecrets() async throws -> [OIDCProviderSnapshot] {
        try await database.withSession(operation: "oidc_providers.list_secrets") { session in
            try await session.execute(
                ListOIDCProvidersWithSecrets(),
                operation: "oidc_providers.list_secrets.query"
            ).map(\.snapshot)
        }
    }

    /// Compare-and-set protects a secret rotated by an administrator while
    /// another replica performs startup encryption convergence.
    @discardableResult
    public func replaceEncryptedClientSecret(
        id: UUID,
        expectedCurrentValue: String,
        replacement: String
    ) async throws -> Bool {
        try await database.withSession(operation: "oidc_providers.replace_secret") { session in
            try await session.execute(
                ReplaceOIDCProviderSecret(
                    id: id,
                    expectedCurrentValue: expectedCurrentValue,
                    replacement: replacement
                ),
                operation: "oidc_providers.replace_secret.query"
            ).count == 1
        }
    }

    private func oneOrNone(_ rows: [OIDCProviderRecord]) throws -> OIDCProviderSnapshot? {
        guard rows.count <= 1 else {
            throw OIDCProviderPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func only(_ rows: [OIDCProviderRecord]) throws -> OIDCProviderSnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw OIDCProviderPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row.snapshot
    }
}

private struct OIDCProviderRecord: Sendable {
    let id: UUID
    let organizationID: UUID
    let name: String
    let clientID: String
    let encryptedClientSecret: String
    let discoveryURL: String?
    let issuer: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let userinfoEndpoint: String?
    let jwksURI: String?
    let endSessionEndpoint: String?
    let discoveredHostsJSON: String
    let scopesJSON: String
    let enabled: Bool
    let useNonce: Bool
    let groupsClaim: String?
    let groupMappingsJSON: String
    let adminClaimValuesJSON: String
    let roleMappingsJSON: String
    let defaultRoleID: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, organizationID, name, clientID, encryptedClientSecret,
            discoveryURL, issuer, authorizationEndpoint, tokenEndpoint,
            userinfoEndpoint, jwksURI, endSessionEndpoint, discoveredHostsJSON,
            scopesJSON, enabled, useNonce, groupsClaim, groupMappingsJSON,
            adminClaimValuesJSON, roleMappingsJSON, defaultRoleID, createdAt, updatedAt
        ) = try row.decode(
            (
                UUID, UUID, String, String, String,
                String?, String?, String?, String?, String?, String?, String?,
                String, String, Bool, Bool, String?, String, String, String,
                UUID?, Date?, Date?
            ).self
        )
    }

    var snapshot: OIDCProviderSnapshot {
        OIDCProviderSnapshot(
            id: id,
            organizationID: organizationID,
            name: name,
            clientID: clientID,
            encryptedClientSecret: encryptedClientSecret,
            discoveryURL: discoveryURL,
            issuer: issuer,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            userinfoEndpoint: userinfoEndpoint,
            jwksURI: jwksURI,
            endSessionEndpoint: endSessionEndpoint,
            discoveredHosts: decodeJSON(discoveredHostsJSON, fallback: []),
            scopes: decodeJSON(scopesJSON, fallback: ["openid", "profile", "email"]),
            enabled: enabled,
            useNonce: useNonce,
            groupsClaim: groupsClaim,
            groupMappings: decodeJSON(groupMappingsJSON, fallback: []),
            adminClaimValues: decodeJSON(adminClaimValuesJSON, fallback: []),
            roleMappings: decodeJSON(roleMappingsJSON, fallback: []),
            defaultRoleID: defaultRoleID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private func encodeJSON<T: Encodable>(_ value: T, fallback: String = "[]") -> String {
    guard let data = try? JSONEncoder().encode(value),
        let string = String(data: data, encoding: .utf8)
    else {
        return fallback
    }
    return string
}

private func decodeJSON<T: Decodable>(_ value: String, fallback: T) -> T {
    guard let data = value.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(T.self, from: data)
    else {
        return fallback
    }
    return decoded
}

private let oidcProviderColumns = """
    id, organization_id, name, client_id, client_secret, discovery_url,
    issuer, authorization_endpoint, token_endpoint, userinfo_endpoint,
    jwks_uri, end_session_endpoint, discovered_hosts, scopes, enabled,
    use_nonce, groups_claim, group_mappings, admin_claim_values,
    role_mappings, default_role_id, created_at, updated_at
    """

private protocol OIDCProviderRecordStatement: PostgresPreparedStatement where Row == OIDCProviderRecord {}

private extension OIDCProviderRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> OIDCProviderRecord {
        try OIDCProviderRecord(row: row)
    }
}

private struct ListOIDCProviders: OIDCProviderRecordStatement {
    static let sql = """
        SELECT \(oidcProviderColumns)
        FROM oidc_providers
        WHERE organization_id = $1
        ORDER BY created_at, id
        """
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct ListEnabledOIDCProviders: OIDCProviderRecordStatement {
    static let sql = """
        SELECT \(oidcProviderColumns)
        FROM oidc_providers
        WHERE organization_id = $1 AND enabled = TRUE
        ORDER BY created_at, id
        """
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindOIDCProvider: OIDCProviderRecordStatement {
    static let sql = "SELECT \(oidcProviderColumns) FROM oidc_providers WHERE id = $1"
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindOwnedOIDCProvider: OIDCProviderRecordStatement {
    static let sql = """
        SELECT \(oidcProviderColumns)
        FROM oidc_providers
        WHERE id = $1 AND organization_id = $2
        """
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindNamedOIDCProvider: OIDCProviderRecordStatement {
    static let sql = """
        SELECT \(oidcProviderColumns)
        FROM oidc_providers
        WHERE organization_id = $1 AND name = $2
        LIMIT 1
        """
    let name: String
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(name)
        return bindings
    }
}

private struct CountOIDCProviders: PostgresPreparedStatement {
    typealias Row = Int64
    static let sql = "SELECT COUNT(*)::bigint FROM oidc_providers WHERE organization_id = $1"
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 {
        try row.decode(Int64.self)
    }
}

private struct InsertOIDCProvider: OIDCProviderRecordStatement {
    static let sql = """
        INSERT INTO oidc_providers (
            id, organization_id, name, client_id, client_secret, discovery_url,
            issuer, authorization_endpoint, token_endpoint, userinfo_endpoint,
            jwks_uri, end_session_endpoint, discovered_hosts, scopes, enabled,
            use_nonce, groups_claim, group_mappings, admin_claim_values,
            role_mappings, default_role_id, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
            $13, $14, $15, $16, $17, $18, $19, $20, $21,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        RETURNING \(oidcProviderColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .text, .text, .text, .text,
        .text, .text, .text, .text, .text, .bool, .bool, .text, .text,
        .text, .text, .uuid,
    ]
    let write: OIDCProviderWrite

    func makeBindings() -> PostgresBindings { providerBindings(write) }
}

private struct ReplaceOIDCProvider: OIDCProviderRecordStatement {
    static let sql = """
        UPDATE oidc_providers
        SET name = $3,
            client_id = $4,
            client_secret = $5,
            discovery_url = $6,
            issuer = $7,
            authorization_endpoint = $8,
            token_endpoint = $9,
            userinfo_endpoint = $10,
            jwks_uri = $11,
            end_session_endpoint = $12,
            discovered_hosts = $13,
            scopes = $14,
            enabled = $15,
            use_nonce = $16,
            groups_claim = $17,
            group_mappings = $18,
            admin_claim_values = $19,
            role_mappings = $20,
            default_role_id = $21,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND organization_id = $2
        RETURNING \(oidcProviderColumns)
        """
    static let bindingDataTypes = InsertOIDCProvider.bindingDataTypes
    let write: OIDCProviderWrite

    func makeBindings() -> PostgresBindings { providerBindings(write) }
}

private func providerBindings(_ write: OIDCProviderWrite) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: 21)
    bindings.append(write.id)
    bindings.append(write.organizationID)
    bindings.append(write.name)
    bindings.append(write.clientID)
    bindings.append(write.encryptedClientSecret)
    bindings.append(write.discoveryURL)
    bindings.append(write.issuer)
    bindings.append(write.authorizationEndpoint)
    bindings.append(write.tokenEndpoint)
    bindings.append(write.userinfoEndpoint)
    bindings.append(write.jwksURI)
    bindings.append(write.endSessionEndpoint)
    bindings.append(encodeJSON(Array(Set(write.discoveredHosts.map { $0.lowercased() })).sorted()))
    bindings.append(encodeJSON(write.scopes, fallback: "[\"openid\",\"profile\",\"email\"]"))
    bindings.append(write.enabled)
    bindings.append(write.useNonce)
    bindings.append(write.groupsClaim)
    bindings.append(encodeJSON(write.groupMappings))
    bindings.append(encodeJSON(write.adminClaimValues))
    bindings.append(encodeJSON(write.roleMappings))
    bindings.append(write.defaultRoleID)
    return bindings
}

private struct LockOwnedOIDCProvider: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        SELECT id FROM oidc_providers
        WHERE id = $1 AND organization_id = $2
        FOR UPDATE
        """
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct CountLinkedOIDCUsers: PostgresPreparedStatement {
    typealias Row = Int64
    static let sql = "SELECT COUNT(*)::bigint FROM users WHERE oidc_provider_id = $1"
    let providerID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(providerID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}

private struct DeleteOwnedOIDCProvider: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = "DELETE FROM oidc_providers WHERE id = $1 AND organization_id = $2 RETURNING id"
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ListOIDCProvidersWithSecrets: OIDCProviderRecordStatement {
    static let sql = """
        SELECT \(oidcProviderColumns)
        FROM oidc_providers
        WHERE client_secret IS NOT NULL
        ORDER BY id
        """

    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ReplaceOIDCProviderSecret: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE oidc_providers
        SET client_secret = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND client_secret = $2
        RETURNING id
        """
    let id: UUID
    let expectedCurrentValue: String
    let replacement: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(expectedCurrentValue)
        bindings.append(replacement)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
