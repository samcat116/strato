import Foundation

public struct OVNLogicalRouterPort: Codable {
    public let uuid: String?
    public let name: String
    public let mac: String
    public let networks: [String]
    public let peer: String?
    public let enabled: Bool?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, mac, networks, peer, enabled, gateway_chassis, ha_chassis_group, options, external_ids
    }
    
    public init(name: String, mac: String, networks: [String], peer: String? = nil, enabled: Bool? = true, gateway_chassis: [String]? = nil, ha_chassis_group: String? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.mac = mac
        self.networks = networks
        self.peer = peer
        self.enabled = enabled
        self.gateway_chassis = gateway_chassis
        self.ha_chassis_group = ha_chassis_group
        self.options = options
        self.external_ids = external_ids
    }
}