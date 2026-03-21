import Foundation

public struct OVNLogicalSwitch: Codable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let acls: [String]?
    public let qosRules: [String]?
    public let dnsRecords: [String]?
    public let loadBalancer: [String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name
        case ports
        case acls
        case qosRules = "qos_rules"
        case dnsRecords = "dns_records"
        case loadBalancer = "load_balancer"
        case other_config
        case external_ids
    }
    
    public init(name: String, ports: [String]? = nil, acls: [String]? = nil, qosRules: [String]? = nil, dnsRecords: [String]? = nil, loadBalancer: [String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.acls = acls
        self.qosRules = qosRules
        self.dnsRecords = dnsRecords
        self.loadBalancer = loadBalancer
        self.other_config = other_config
        self.external_ids = external_ids
    }
}