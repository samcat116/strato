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
    var name: String // Display name like "Azure AD", "Google Workspace"

    @Field(key: "client_id")
    var clientID: String

    @Field(key: "client_secret")
    var clientSecret: String

    @OptionalField(key: "discovery_url")
    var discoveryURL: String? // OpenID Connect discovery endpoint

    @OptionalField(key: "authorization_endpoint")
    var authorizationEndpoint: String?

    @OptionalField(key: "token_endpoint")
    var tokenEndpoint: String?

    @OptionalField(key: "userinfo_endpoint")
    var userinfoEndpoint: String?

    @OptionalField(key: "jwks_uri")
    var jwksURI: String?

    @Field(key: "scopes")
    var scopes: String // JSON array of scopes, default: ["openid", "profile", "email"]

    @Field(key: "enabled")
    var enabled: Bool

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
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        userinfoEndpoint: String? = nil,
        jwksURI: String? = nil,
        scopes: [String] = ["openid", "profile", "email"],
        enabled: Bool = true
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.name = name
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.discoveryURL = discoveryURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.jwksURI = jwksURI
        self.scopes = Self.encodeScopesArray(scopes)
        self.enabled = enabled
    }
}

extension OIDCProvider: Content {}

// MARK: - Helper Methods

extension OIDCProvider {
    /// Get scopes as an array
    var scopesArray: [String] {
        get {
            guard let data = scopes.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
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
        guard let data = try? JSONEncoder().encode(scopesArray),
              let string = String(data: data, encoding: .utf8) else {
            return "[\"openid\",\"profile\",\"email\"]"
        }
        return string
    }

    /// Check if the provider has the required endpoints configured
    func hasRequiredEndpoints() -> Bool {
        return authorizationEndpoint != nil && tokenEndpoint != nil
    }

    /// Get the authorization URL for this provider
    func getAuthorizationURL(
        redirectURI: String,
        state: String,
        nonce: String,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil
    ) -> String? {
        guard let authEndpoint = authorizationEndpoint else { return nil }
        
        var components = URLComponents(string: authEndpoint)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopesArray.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce)
        ]
        
        // Add PKCE parameters if provided
        if let codeChallenge = codeChallenge,
           let codeChallengeMethod = codeChallengeMethod {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod))
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
    let scopes: [String]?
    let enabled: Bool?
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
    let scopes: [String]?
    let enabled: Bool?
}

struct OIDCProviderResponse: Content {
    let id: UUID?
    let name: String
    let clientID: String
    let discoveryURL: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let userinfoEndpoint: String?
    let jwksURI: String?
    let scopes: [String]
    let enabled: Bool
    let createdAt: Date?
    let updatedAt: Date?

    init(from provider: OIDCProvider) {
        self.id = provider.id
        self.name = provider.name
        self.clientID = provider.clientID
        // Note: We don't expose client_secret in responses for security
        self.discoveryURL = provider.discoveryURL
        self.authorizationEndpoint = provider.authorizationEndpoint
        self.tokenEndpoint = provider.tokenEndpoint
        self.userinfoEndpoint = provider.userinfoEndpoint
        self.jwksURI = provider.jwksURI
        self.scopes = provider.scopesArray
        self.enabled = provider.enabled
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