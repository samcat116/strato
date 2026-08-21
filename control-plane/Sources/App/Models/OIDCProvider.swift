import ControlPlanePostgres
import Foundation
import Vapor

/// Maps a value of the provider's groups claim to a Strato group.
struct OIDCGroupMapping: Content, Equatable, Sendable {
    let claimValue: String
    let groupID: UUID

    init(claimValue: String, groupID: UUID) {
        self.claimValue = claimValue
        self.groupID = groupID
    }

    init(_ value: OIDCGroupMappingValue) {
        self.init(claimValue: value.claimValue, groupID: value.groupID)
    }

    var persistenceValue: OIDCGroupMappingValue {
        OIDCGroupMappingValue(claimValue: claimValue, groupID: groupID)
    }
}

/// Maps a value of the provider's groups claim to an organization role.
struct OIDCRoleMapping: Content, Equatable, Sendable {
    let claimValue: String
    let roleID: UUID

    init(claimValue: String, roleID: UUID) {
        self.claimValue = claimValue
        self.roleID = roleID
    }

    init(_ value: OIDCRoleMappingValue) {
        self.init(claimValue: value.claimValue, roleID: value.roleID)
    }

    var persistenceValue: OIDCRoleMappingValue {
        OIDCRoleMappingValue(claimValue: claimValue, roleID: roleID)
    }
}

extension OIDCProviderSnapshot {
    var groupMappingsForTransport: [OIDCGroupMapping] { groupMappings.map(OIDCGroupMapping.init) }
    var roleMappingsForTransport: [OIDCRoleMapping] { roleMappings.map(OIDCRoleMapping.init) }

    func getAuthorizationURL(
        redirectURI: String,
        state: String,
        nonce: String?,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil
    ) -> String? {
        authorizationURL(
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            codeChallengeMethod: codeChallengeMethod
        )
    }

    func getEndSessionURL(idTokenHint: String?, postLogoutRedirectURI: String?) -> String? {
        endSessionURL(idTokenHint: idTokenHint, postLogoutRedirectURI: postLogoutRedirectURI)
    }
}

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
    let defaultRoleID: UUID?

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
        defaultRoleID: UUID? = nil
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
        self.defaultRoleID = defaultRoleID
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
    let defaultRoleID: UUID?
    /// `nil` is a meaningful update, so retain omitted versus explicit null.
    let updatesDefaultRoleID: Bool

    enum CodingKeys: String, CodingKey {
        case name, clientID, clientSecret, discoveryURL, authorizationEndpoint
        case tokenEndpoint, userinfoEndpoint, jwksURI, endSessionEndpoint
        case scopes, enabled, useNonce, groupsClaim, groupMappings
        case adminClaimValues, roleMappings, defaultRoleID
    }

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
        defaultRoleID: UUID? = nil,
        clearDefaultRoleID: Bool = false
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
        self.defaultRoleID = defaultRoleID
        self.updatesDefaultRoleID = defaultRoleID != nil || clearDefaultRoleID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        clientID = try values.decodeIfPresent(String.self, forKey: .clientID)
        clientSecret = try values.decodeIfPresent(String.self, forKey: .clientSecret)
        discoveryURL = try values.decodeIfPresent(String.self, forKey: .discoveryURL)
        authorizationEndpoint = try values.decodeIfPresent(String.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try values.decodeIfPresent(String.self, forKey: .tokenEndpoint)
        userinfoEndpoint = try values.decodeIfPresent(String.self, forKey: .userinfoEndpoint)
        jwksURI = try values.decodeIfPresent(String.self, forKey: .jwksURI)
        endSessionEndpoint = try values.decodeIfPresent(String.self, forKey: .endSessionEndpoint)
        scopes = try values.decodeIfPresent([String].self, forKey: .scopes)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
        useNonce = try values.decodeIfPresent(Bool.self, forKey: .useNonce)
        groupsClaim = try values.decodeIfPresent(String.self, forKey: .groupsClaim)
        groupMappings = try values.decodeIfPresent([OIDCGroupMapping].self, forKey: .groupMappings)
        adminClaimValues = try values.decodeIfPresent([String].self, forKey: .adminClaimValues)
        roleMappings = try values.decodeIfPresent([OIDCRoleMapping].self, forKey: .roleMappings)
        defaultRoleID = try values.decodeIfPresent(UUID.self, forKey: .defaultRoleID)
        updatesDefaultRoleID = values.contains(.defaultRoleID)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(clientID, forKey: .clientID)
        try values.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try values.encodeIfPresent(discoveryURL, forKey: .discoveryURL)
        try values.encodeIfPresent(authorizationEndpoint, forKey: .authorizationEndpoint)
        try values.encodeIfPresent(tokenEndpoint, forKey: .tokenEndpoint)
        try values.encodeIfPresent(userinfoEndpoint, forKey: .userinfoEndpoint)
        try values.encodeIfPresent(jwksURI, forKey: .jwksURI)
        try values.encodeIfPresent(endSessionEndpoint, forKey: .endSessionEndpoint)
        try values.encodeIfPresent(scopes, forKey: .scopes)
        try values.encodeIfPresent(enabled, forKey: .enabled)
        try values.encodeIfPresent(useNonce, forKey: .useNonce)
        try values.encodeIfPresent(groupsClaim, forKey: .groupsClaim)
        try values.encodeIfPresent(groupMappings, forKey: .groupMappings)
        try values.encodeIfPresent(adminClaimValues, forKey: .adminClaimValues)
        try values.encodeIfPresent(roleMappings, forKey: .roleMappings)
        if updatesDefaultRoleID {
            try values.encode(defaultRoleID, forKey: .defaultRoleID)
        }
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
    let defaultRoleID: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from provider: OIDCProviderSnapshot, includeClaimMappings: Bool = true) {
        id = provider.id
        name = provider.name
        clientID = provider.clientID
        discoveryURL = provider.discoveryURL
        issuer = provider.issuer
        authorizationEndpoint = provider.authorizationEndpoint
        tokenEndpoint = provider.tokenEndpoint
        userinfoEndpoint = provider.userinfoEndpoint
        jwksURI = provider.jwksURI
        endSessionEndpoint = provider.endSessionEndpoint
        scopes = provider.scopes
        enabled = provider.enabled
        useNonce = provider.useNonce
        groupsClaim = includeClaimMappings ? provider.groupsClaim : nil
        groupMappings = includeClaimMappings ? provider.groupMappingsForTransport : nil
        adminClaimValues = includeClaimMappings ? provider.adminClaimValues : nil
        roleMappings = includeClaimMappings ? provider.roleMappingsForTransport : nil
        defaultRoleID = includeClaimMappings ? provider.defaultRoleID : nil
        createdAt = provider.createdAt
        updatedAt = provider.updatedAt
    }
}

struct OIDCProviderPublicResponse: Content {
    let id: UUID?
    let name: String
    let enabled: Bool

    init(from provider: OIDCProviderSnapshot) {
        id = provider.id
        name = provider.name
        enabled = provider.enabled
    }
}

struct SSOLookupResponse: Content {
    let organizationID: UUID?
    let providers: [OIDCProviderPublicResponse]
}

struct OIDCProviderTestResponse: Content {
    let valid: Bool
    let message: String
}
