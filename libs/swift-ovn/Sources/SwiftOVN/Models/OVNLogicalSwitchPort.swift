import Foundation

public struct OVNLogicalSwitchPort: Codable {
    public let uuid: String?
    public let name: String
    public let portType: String?
    public let options: [String: String]?
    public let addresses: [String]?
    public let port_security: [String]?
    public let dhcpv4_options: String?
    public let dhcpv6_options: String?
    public let tag: Int?
    public let tag_request: Int?
    public let up: Bool?
    public let enabled: Bool?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, options, addresses
        case port_security, dhcpv4_options, dhcpv6_options
        case tag, tag_request, up, enabled, external_ids
        case portType = "type"
    }
    
    public init(name: String, portType: String? = nil, options: [String: String]? = nil, addresses: [String]? = nil, port_security: [String]? = nil, dhcpv4_options: String? = nil, dhcpv6_options: String? = nil, tag: Int? = nil, tag_request: Int? = nil, up: Bool? = nil, enabled: Bool? = true, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.portType = portType
        self.options = options
        self.addresses = addresses
        self.port_security = port_security
        self.dhcpv4_options = dhcpv4_options
        self.dhcpv6_options = dhcpv6_options
        self.tag = tag
        self.tag_request = tag_request
        self.up = up
        self.enabled = enabled
        self.external_ids = external_ids
    }
}