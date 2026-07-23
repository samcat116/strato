import Fluent
import Vapor
import Foundation

final class OIDCProvider: Model, @unchecked Sendable {
    static let schema = "oidc_providers"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String  // Display name like "Azure AD", "Google Workspace"

    @Field(key: "client_id")
    var clientID: String

    // Encrypted at rest (`enc:v1:` prefix) via SecretsEncryptionService;
    // read through decrypt().
    @Field(key: "client_secret")
    var clientSecret: String

    @OptionalField(key: "discovery_url")
    var discoveryURL: String?  // OpenID Connect discovery endpoint

    @OptionalField(key: "issuer")
    var issuer: String?  // Expected `iss` claim; populated from the discovery document

    @OptionalField(key: "authorization_endpoint")
    var authorizationEndpoint: String?

    @OptionalField(key: "token_endpoint")
    var tokenEndpoint: String?

    @OptionalField(key: "userinfo_endpoint")
    var userinfoEndpoint: String?

    @OptionalField(key: "jwks_uri")
    var jwksURI: String?

    @OptionalField(key: "end_session_endpoint")
    var endSessionEndpoint: String?  // RP-initiated logout (OIDC Session Management)

    // JSON array of hosts this provider's own discovery document named as its
    // server-fetched endpoints (token, userinfo, JWKS). An allow-listed issuer
    // vouching for a host is what makes it fetchable, so an IdP that serves
    // JWKS from a different domain than its discovery URL (Google: discovery on
    // accounts.google.com, keys on www.googleapis.com) works without every
    // operator hand-maintaining OIDC_DISCOVERY_ALLOWED_HOSTS. Rewritten in full
    // on each discovery refresh so repointing a provider drops stale trust, and
    // deliberately NOT extended by manually-set endpoints — those have no
    // issuer vouching for them and stay gated by the global allow-list.
    @Field(key: "discovered_hosts")
    var discoveredHosts: String

    @Field(key: "scopes")
    var scopes: String  // JSON array of scopes, default: ["openid", "profile", "email"]

    @Field(key: "enabled")
    var enabled: Bool

    // When true (default, OIDC-compliant), Strato sends a `nonce` on the
    // authorization request and requires the ID token to echo it. Some IdPs —
    // notably Discord — accept the nonce but never return it, failing every
    // login; disable this per provider to skip sending and validating it.
    // PKCE (S256) + `state` still protect the authorization-code flow.
    @Field(key: "use_nonce")
    var useNonce: Bool

    @OptionalField(key: "groups_claim")
    var groupsClaim: String?  // ID-token claim holding group/role values (e.g. "groups", "roles")

    @Field(key: "group_mappings")
    var groupMappings: String  // JSON array of OIDCGroupMapping

    @Field(key: "admin_claim_values")
    var adminClaimValues: String  // JSON array of claim values granting the org "admin" role

    @Field(key: "role_mappings")
    var roleMappings: String  // JSON array of OIDCRoleMapping (claim value → org role id)

    // Org role for JIT-provisioned users when no claim matches, default
    // "member". May also be an IAM role name or an org-owned role id (#611).
    @Field(key: "default_role")
    var defaultRole: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // Relationships
    @Children(for: \.$oidcProvider)
    var users: [User]

    init() {}

    init(
        id: UUID? = nil,
        organizationID: UUID,
        name: String,
        clientID: String,
        clientSecret: String,
        discoveryURL: String? = nil,
        issuer: String? = nil,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        userinfoEndpoint: String? = nil,
        jwksURI: String? = nil,
        endSessionEndpoint: String? = nil,
        scopes: [String] = ["openid", "profile", "email"],
        enabled: Bool = true,
        useNonce: Bool = true,
        groupsClaim: String? = nil,
        groupMappings: [OIDCGroupMapping] = [],
        adminClaimValues: [String] = [],
        roleMappings: [OIDCRoleMapping] = [],
        defaultRole: String = "member"
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.name = name
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.discoveryURL = discoveryURL
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.jwksURI = jwksURI
        self.endSessionEndpoint = endSessionEndpoint
        self.discoveredHosts = "[]"
        self.scopes = Self.encodeScopesArray(scopes)
        self.enabled = enabled
        self.useNonce = useNonce
        self.groupsClaim = groupsClaim
        self.groupMappings = Self.encodeJSON(groupMappings, fallback: "[]")
        self.adminClaimValues = Self.encodeJSON(adminClaimValues, fallback: "[]")
        self.roleMappings = Self.encodeJSON(roleMappings, fallback: "[]")
        self.defaultRole = defaultRole
    }
}

/// Maps a value of the provider's groups claim to a Strato group. Groups that
/// appear in a provider's mappings are IdP-managed: on every OIDC login the
/// user's membership is added or removed to match the token's claim values.
struct OIDCGroupMapping: Content, Equatable {
    /// The claim value as sent by the IdP (a group name, or an object ID for
    /// IdPs like Entra ID that emit group GUIDs).
    let claimValue: String
    /// The Strato group (must belong to the provider's organization).
    let groupID: UUID
}

/// Maps a value of the provider's groups claim to a Strato role bound on the
/// organization node (issue #611). When a login token carries the claim value,
/// the user's org membership is reconciled to this role — the claim-driven
/// analog of the org member endpoints accepting scoped role ids (#608). The
/// role must be bindable at the org: platform-owned, or owned by the provider's
/// organization or one of its ancestors.
struct OIDCRoleMapping: Content, Equatable {
    /// The claim value as sent by the IdP.
    let claimValue: String
    /// The role to bind on the org node.
    let roleID: UUID
}

extension OIDCProvider: Content {}

// MARK: - Helper Methods

extension OIDCProvider {
    /// Get scopes as an array
    var scopesArray: [String] {
        get {
            guard let data = scopes.data(using: .utf8),
                let array = try? JSONDecoder().decode([String].self, from: data)
            else {
                return ["openid", "profile", "email"]
            }
            return array
        }
    }

    /// Set scopes from an array
    func setScopesArray(_ scopesArray: [String]) {
        self.scopes = Self.encodeScopesArray(scopesArray)
    }

    /// Encode scopes array to JSON string
    private static func encodeScopesArray(_ scopesArray: [String]) -> String {
        return encodeJSON(scopesArray, fallback: "[\"openid\",\"profile\",\"email\"]")
    }

    static func encodeJSON<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return string
    }

    /// Get group mappings as a typed array
    var groupMappingsArray: [OIDCGroupMapping] {
        guard let data = groupMappings.data(using: .utf8),
            let array = try? JSONDecoder().decode([OIDCGroupMapping].self, from: data)
        else {
            return []
        }
        return array
    }

    /// Set group mappings from a typed array
    func setGroupMappingsArray(_ mappings: [OIDCGroupMapping]) {
        self.groupMappings = Self.encodeJSON(mappings, fallback: "[]")
    }

    /// Get admin claim values as an array
    var adminClaimValuesArray: [String] {
        guard let data = adminClaimValues.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return array
    }

    /// Set admin claim values from an array
    func setAdminClaimValuesArray(_ values: [String]) {
        self.adminClaimValues = Self.encodeJSON(values, fallback: "[]")
    }

    /// Get role mappings as a typed array
    var roleMappingsArray: [OIDCRoleMapping] {
        guard let data = roleMappings.data(using: .utf8),
            let array = try? JSONDecoder().decode([OIDCRoleMapping].self, from: data)
        else {
            return []
        }
        return array
    }

    /// Set role mappings from a typed array
    func setRoleMappingsArray(_ mappings: [OIDCRoleMapping]) {
        self.roleMappings = Self.encodeJSON(mappings, fallback: "[]")
    }

    /// Hosts this provider's discovery document vouched for, as a set for the
    /// SSRF allow-list check on token/userinfo/JWKS fetches.
    var discoveredHostSet: Set<String> {
        guard let data = discoveredHosts.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(array)
    }

    /// Records the hosts of the endpoints a discovery document supplied.
    /// Replaces the previous set rather than merging: an IdP that moves or a
    /// provider repointed at a different one must not keep trusting the old
    /// document's hosts. Only endpoints Strato fetches server-side are
    /// recorded — the authorization and end-session endpoints are browser
    /// redirects, never server fetches, so they need no fetch allow-list entry.
    func setDiscoveredHosts(from discovery: OIDCDiscoveryDocument) {
        let hosts = [discovery.tokenEndpoint, discovery.userinfoEndpoint, discovery.jwksURI]
            .compactMap { $0 }
            .compactMap { URL(string: $0)?.host }
        self.discoveredHosts = Self.encodeJSON(Array(Set(hosts)).sorted(), fallback: "[]")
    }

    /// Check if the provider has the required endpoints configured.
    /// JWKS is required too: the callback path can't validate ID tokens
    /// without it, so a provider missing it can never complete a login.
    func hasRequiredEndpoints() -> Bool {
        return authorizationEndpoint != nil && tokenEndpoint != nil && jwksURI != nil
    }

    /// Get the authorization URL for this provider
    func getAuthorizationURL(
        redirectURI: String,
        state: String,
        nonce: String?,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil
    ) -> String? {
        guard let authEndpoint = authorizationEndpoint else { return nil }

        var components = URLComponents(string: authEndpoint)
        // Seed with the endpoint's own query items — some IdPs embed tenant or
        // policy selectors in the URL (e.g. Azure AD B2C's `?p=<policy>`), and
        // overwriting them would send the request to the wrong flow.
        var queryItems: [URLQueryItem] = components?.queryItems ?? []
        queryItems += [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopesArray.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        // Only request a nonce when the provider supports echoing it back
        // (see `useNonce`); omit it entirely otherwise.
        if let nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }

        // Add PKCE parameters if provided
        if let codeChallenge = codeChallenge,
            let codeChallengeMethod = codeChallengeMethod
        {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod))
        }

        components?.queryItems = queryItems
        return components?.url?.absoluteString
    }

    /// Builds the RP-initiated logout URL (OIDC RP-Initiated Logout 1.0).
    /// `id_token_hint` tells the IdP which session to end without a prompt;
    /// `post_logout_redirect_uri` must be registered with the IdP alongside
    /// the login redirect URI for the IdP to honor it.
    func getEndSessionURL(idTokenHint: String?, postLogoutRedirectURI: String?) -> String? {
        guard let endSessionEndpoint else { return nil }

        var components = URLComponents(string: endSessionEndpoint)
        // Preserve the endpoint's own query items (tenant/policy selectors),
        // same as getAuthorizationURL.
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

// MARK: - DTOs

struct CreateOIDCProviderRequest: Content {
    let name: String
    let clientID: String
    let clientSecret: String
    let discoveryURL: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let userinfoEndpoint: String?
    let jwksURI: String?
    let endSessionEndpoint: String?
    let scopes: [String]?
    let enabled: Bool?
    let useNonce: Bool?
    let groupsClaim: String?
    let groupMappings: [OIDCGroupMapping]?
    let adminClaimValues: [String]?
    let roleMappings: [OIDCRoleMapping]?
    let defaultRole: String?

    init(
        name: String,
        clientID: String,
        clientSecret: String,
        discoveryURL: String? = nil,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        userinfoEndpoint: String? = nil,
        jwksURI: String? = nil,
        endSessionEndpoint: String? = nil,
        scopes: [String]? = nil,
        enabled: Bool? = nil,
        useNonce: Bool? = nil,
        groupsClaim: String? = nil,
        groupMappings: [OIDCGroupMapping]? = nil,
        adminClaimValues: [String]? = nil,
        roleMappings: [OIDCRoleMapping]? = nil,
        defaultRole: String? = nil
    ) {
        self.name = name
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.discoveryURL = discoveryURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.jwksURI = jwksURI
        self.endSessionEndpoint = endSessionEndpoint
        self.scopes = scopes
        self.enabled = enabled
        self.useNonce = useNonce
        self.groupsClaim = groupsClaim
        self.groupMappings = groupMappings
        self.adminClaimValues = adminClaimValues
        self.roleMappings = roleMappings
        self.defaultRole = defaultRole
    }
}

struct UpdateOIDCProviderRequest: Content {
    let name: String?
    let clientID: String?
    let clientSecret: String?
    let discoveryURL: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let userinfoEndpoint: String?
    let jwksURI: String?
    let endSessionEndpoint: String?
    let scopes: [String]?
    let enabled: Bool?
    let useNonce: Bool?
    let groupsClaim: String?
    let groupMappings: [OIDCGroupMapping]?
    let adminClaimValues: [String]?
    let roleMappings: [OIDCRoleMapping]?
    let defaultRole: String?

    init(
        name: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil,
        discoveryURL: String? = nil,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        userinfoEndpoint: String? = nil,
        jwksURI: String? = nil,
        endSessionEndpoint: String? = nil,
        scopes: [String]? = nil,
        enabled: Bool? = nil,
        useNonce: Bool? = nil,
        groupsClaim: String? = nil,
        groupMappings: [OIDCGroupMapping]? = nil,
        adminClaimValues: [String]? = nil,
        roleMappings: [OIDCRoleMapping]? = nil,
        defaultRole: String? = nil
    ) {
        self.name = name
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.discoveryURL = discoveryURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.jwksURI = jwksURI
        self.endSessionEndpoint = endSessionEndpoint
        self.scopes = scopes
        self.enabled = enabled
        self.useNonce = useNonce
        self.groupsClaim = groupsClaim
        self.groupMappings = groupMappings
        self.adminClaimValues = adminClaimValues
        self.roleMappings = roleMappings
        self.defaultRole = defaultRole
    }
}

struct OIDCProviderResponse: Content {
    let id: UUID?
    let name: String
    let clientID: String
    let discoveryURL: String?
    let issuer: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let userinfoEndpoint: String?
    let jwksURI: String?
    let endSessionEndpoint: String?
    let scopes: [String]
    let enabled: Bool
    let useNonce: Bool
    let groupsClaim: String?
    let groupMappings: [OIDCGroupMapping]?
    let adminClaimValues: [String]?
    let roleMappings: [OIDCRoleMapping]?
    let defaultRole: String?
    let createdAt: Date?
    let updatedAt: Date?

    /// Claim-mapping fields describe which IdP claims grant which Strato
    /// groups and the admin role — administration detail that plain org
    /// members have no need to see. Pass `includeClaimMappings: false` on
    /// member-accessible read paths to redact them.
    init(from provider: OIDCProvider, includeClaimMappings: Bool = true) {
        self.id = provider.id
        self.name = provider.name
        self.clientID = provider.clientID
        // Note: We don't expose client_secret in responses for security
        self.discoveryURL = provider.discoveryURL
        self.issuer = provider.issuer
        self.authorizationEndpoint = provider.authorizationEndpoint
        self.tokenEndpoint = provider.tokenEndpoint
        self.userinfoEndpoint = provider.userinfoEndpoint
        self.jwksURI = provider.jwksURI
        self.endSessionEndpoint = provider.endSessionEndpoint
        self.scopes = provider.scopesArray
        self.enabled = provider.enabled
        self.useNonce = provider.useNonce
        self.groupsClaim = includeClaimMappings ? provider.groupsClaim : nil
        self.groupMappings = includeClaimMappings ? provider.groupMappingsArray : nil
        self.adminClaimValues = includeClaimMappings ? provider.adminClaimValuesArray : nil
        self.roleMappings = includeClaimMappings ? provider.roleMappingsArray : nil
        self.defaultRole = includeClaimMappings ? provider.defaultRole : nil
        self.createdAt = provider.createdAt
        self.updatedAt = provider.updatedAt
    }
}

struct OIDCProviderPublicResponse: Content {
    let id: UUID?
    let name: String
    let enabled: Bool

    init(from provider: OIDCProvider) {
        self.id = provider.id
        self.name = provider.name
        self.enabled = provider.enabled
    }
}

/// Anonymous login-page lookup: resolves an organization name to its enabled
/// SSO providers. `organizationID` is nil when the organization doesn't exist
/// OR has no enabled providers, so the response doesn't reveal which org names
/// exist.
struct SSOLookupResponse: Content {
    let organizationID: UUID?
    let providers: [OIDCProviderPublicResponse]
}

struct OIDCProviderTestResponse: Content {
    let valid: Bool
    let message: String
}
