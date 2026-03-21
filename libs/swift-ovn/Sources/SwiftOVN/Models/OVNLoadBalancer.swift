import Foundation

public struct OVNLoadBalancer: Codable {
    public let uuid: String?
    public let name: String
    public let vips: [String: String]
    public let protocolType: String?
    public let health_check: [String]?
    public let ip_port_mappings: [String: String]?
    public let selection_fields: [String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, vips, health_check, ip_port_mappings, selection_fields, options, external_ids
        case protocolType = "protocol"
    }
    
    public init(name: String, vips: [String: String], protocolType: String? = nil, health_check: [String]? = nil, ip_port_mappings: [String: String]? = nil, selection_fields: [String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.vips = vips
        self.protocolType = protocolType
        self.health_check = health_check
        self.ip_port_mappings = ip_port_mappings
        self.selection_fields = selection_fields
        self.options = options
        self.external_ids = external_ids
    }
}