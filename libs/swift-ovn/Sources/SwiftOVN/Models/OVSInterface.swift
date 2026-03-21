import Foundation

public struct OVSInterface: Codable {
    public let uuid: String?
    public let name: String
    public let interfaceType: String?
    public let options: [String: String]?
    public let ingress_policing_rate: Int?
    public let ingress_policing_burst: Int?
    public let mac_in_use: String?
    public let mac: String?
    public let ifindex: Int?
    public let external_ids: [String: String]?
    public let other_config: [String: String]?
    public let statistics: [String: Int]?
    public let status: [String: String]?
    public let admin_state: String?
    public let link_state: String?
    public let link_resets: Int?
    public let link_speed: Int?
    public let duplex: String?
    public let mtu: Int?
    public let error: String?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, options, ingress_policing_rate, ingress_policing_burst, mac_in_use, mac, ifindex, external_ids, other_config, statistics, status, admin_state, link_state, link_resets, link_speed, duplex, mtu, error
        case interfaceType = "type"
    }
    
    public init(name: String, interfaceType: String? = nil, options: [String: String]? = nil, ingress_policing_rate: Int? = nil, ingress_policing_burst: Int? = nil, mac_in_use: String? = nil, mac: String? = nil, ifindex: Int? = nil, external_ids: [String: String]? = nil, other_config: [String: String]? = nil, statistics: [String: Int]? = nil, status: [String: String]? = nil, admin_state: String? = nil, link_state: String? = nil, link_resets: Int? = nil, link_speed: Int? = nil, duplex: String? = nil, mtu: Int? = nil, error: String? = nil) {
        self.uuid = nil
        self.name = name
        self.interfaceType = interfaceType
        self.options = options
        self.ingress_policing_rate = ingress_policing_rate
        self.ingress_policing_burst = ingress_policing_burst
        self.mac_in_use = mac_in_use
        self.mac = mac
        self.ifindex = ifindex
        self.external_ids = external_ids
        self.other_config = other_config
        self.statistics = statistics
        self.status = status
        self.admin_state = admin_state
        self.link_state = link_state
        self.link_resets = link_resets
        self.link_speed = link_speed
        self.duplex = duplex
        self.mtu = mtu
        self.error = error
    }
}