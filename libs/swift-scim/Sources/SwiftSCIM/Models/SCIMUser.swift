import Foundation

/// SCIM User resource
public struct SCIMUser: SCIMResource {
    public let id: String?
    public var externalId: String?
    public let meta: SCIMResourceMeta?
    public let schemas: [String]
    
    /// Required: Unique identifier for the User
    public let userName: String
    
    /// Name components
    public let name: UserName?
    
    /// Display name for the User
    public let displayName: String?
    
    /// Nickname for the User
    public let nickName: String?
    
    /// Profile URL for the User
    public let profileUrl: String?
    
    /// Title for the User
    public let title: String?
    
    /// Type of User
    public let userType: String?
    
    /// Preferred written or spoken language
    public let preferredLanguage: String?
    
    /// User's locale
    public let locale: String?
    
    /// User's time zone
    public let timezone: String?
    
    /// Boolean value indicating User's administrative status
    public let active: Bool?
    
    /// Password for the User
    public let password: String?
    
    /// Email addresses for the user
    public let emails: [SCIMMultiValuedAttribute<String>]?
    
    /// Phone numbers for the User
    public let phoneNumbers: [SCIMMultiValuedAttribute<String>]?
    
    /// Instant messaging addresses for the User
    public let ims: [SCIMMultiValuedAttribute<String>]?
    
    /// Photos for the User
    public let photos: [SCIMMultiValuedAttribute<String>]?
    
    /// Physical mailing addresses for the User
    public let addresses: [UserAddress]?
    
    /// Groups to which the user belongs
    public let groups: [UserGroup]?
    
    /// Entitlements for the User
    public let entitlements: [SCIMMultiValuedAttribute<String>]?
    
    /// Roles for the User
    public let roles: [SCIMMultiValuedAttribute<String>]?
    
    /// X.509 certificates for the User
    public let x509Certificates: [SCIMMultiValuedAttribute<String>]?
    
    public init(
        id: String? = nil,
        externalId: String? = nil,
        meta: SCIMResourceMeta? = nil,
        userName: String,
        name: UserName? = nil,
        displayName: String? = nil,
        nickName: String? = nil,
        profileUrl: String? = nil,
        title: String? = nil,
        userType: String? = nil,
        preferredLanguage: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        active: Bool? = nil,
        password: String? = nil,
        emails: [SCIMMultiValuedAttribute<String>]? = nil,
        phoneNumbers: [SCIMMultiValuedAttribute<String>]? = nil,
        ims: [SCIMMultiValuedAttribute<String>]? = nil,
        photos: [SCIMMultiValuedAttribute<String>]? = nil,
        addresses: [UserAddress]? = nil,
        groups: [UserGroup]? = nil,
        entitlements: [SCIMMultiValuedAttribute<String>]? = nil,
        roles: [SCIMMultiValuedAttribute<String>]? = nil,
        x509Certificates: [SCIMMultiValuedAttribute<String>]? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.meta = meta
        self.schemas = ["urn:ietf:params:scim:schemas:core:2.0:User"]
        self.userName = userName
        self.name = name
        self.displayName = displayName
        self.nickName = nickName
        self.profileUrl = profileUrl
        self.title = title
        self.userType = userType
        self.preferredLanguage = preferredLanguage
        self.locale = locale
        self.timezone = timezone
        self.active = active
        self.password = password
        self.emails = emails
        self.phoneNumbers = phoneNumbers
        self.ims = ims
        self.photos = photos
        self.addresses = addresses
        self.groups = groups
        self.entitlements = entitlements
        self.roles = roles
        self.x509Certificates = x509Certificates
    }
}

/// Components of the user's real name
public struct UserName: Codable, Sendable {
    /// Family name of the User
    public let familyName: String?
    
    /// Given name of the User
    public let givenName: String?
    
    /// Middle name(s) of the User
    public let middleName: String?
    
    /// Honorific prefix(es) of the User
    public let honorificPrefix: String?
    
    /// Honorific suffix(es) of the User
    public let honorificSuffix: String?
    
    /// Full name, including all middle names, titles, and suffixes
    public let formatted: String?
    
    public init(
        familyName: String? = nil,
        givenName: String? = nil,
        middleName: String? = nil,
        honorificPrefix: String? = nil,
        honorificSuffix: String? = nil,
        formatted: String? = nil
    ) {
        self.familyName = familyName
        self.givenName = givenName
        self.middleName = middleName
        self.honorificPrefix = honorificPrefix
        self.honorificSuffix = honorificSuffix
        self.formatted = formatted
    }
}

/// Physical mailing address for a User
public struct UserAddress: Codable, Sendable {
    /// Full mailing address, formatted for display
    public let formatted: String?
    
    /// Full street address component
    public let streetAddress: String?
    
    /// City or locality component
    public let locality: String?
    
    /// State or region component
    public let region: String?
    
    /// Zip or postal code component
    public let postalCode: String?
    
    /// Country name component
    public let country: String?
    
    /// Type of address
    public let type: String?
    
    /// Boolean value indicating if this is the primary address
    public let primary: Bool?
    
    public init(
        formatted: String? = nil,
        streetAddress: String? = nil,
        locality: String? = nil,
        region: String? = nil,
        postalCode: String? = nil,
        country: String? = nil,
        type: String? = nil,
        primary: Bool? = nil
    ) {
        self.formatted = formatted
        self.streetAddress = streetAddress
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.type = type
        self.primary = primary
    }
}

/// Group to which the user belongs
public struct UserGroup: Codable, Sendable {
    /// Identifier of the User's group
    public let value: String?
    
    /// URI of the corresponding Group resource
    public let ref: String?
    
    /// Human-readable name for the Group
    public let display: String?
    
    /// Type of group membership
    public let type: String?
    
    public init(
        value: String? = nil,
        ref: String? = nil,
        display: String? = nil,
        type: String? = nil
    ) {
        self.value = value
        self.ref = ref
        self.display = display
        self.type = type
    }
    
    private enum CodingKeys: String, CodingKey {
        case value
        case ref = "$ref"
        case display
        case type
    }
}