import Foundation

/// SCIM Group resource
public struct SCIMGroup: SCIMResource {
    public let id: String?
    public var externalId: String?
    public let meta: SCIMResourceMeta?
    public let schemas: [String]
    
    /// Required: Human-readable name for the Group
    public let displayName: String
    
    /// List of members of the Group
    public let members: [GroupMember]?
    
    public init(
        id: String? = nil,
        externalId: String? = nil,
        meta: SCIMResourceMeta? = nil,
        displayName: String,
        members: [GroupMember]? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.meta = meta
        self.schemas = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
        self.displayName = displayName
        self.members = members
    }
}

/// Member of a Group
public struct GroupMember: Codable, Sendable {
    /// Identifier of the member
    public let value: String?
    
    /// URI of the corresponding resource
    public let ref: String?
    
    /// Human-readable name for the member
    public let display: String?
    
    /// Type of member (User, Group)
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