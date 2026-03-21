import Foundation

public struct OVSPort: Codable {
    public let uuid: String?
    public let name: String
    public let interfaces: [String]
    public let trunks: [Int]?
    public let tag: Int?
    public let vlan_mode: String?
    public let qos: String?
    public let mac: String?
    public let bond_mode: String?
    public let lacp: String?
    public let bond_updelay: Int?
    public let bond_downdelay: Int?
    public let bond_fake_iface: Bool?
    public let fake_bridge: Bool?
    public let status: [String: String]?
    public let statistics: [String: Int]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, interfaces, trunks, tag, vlan_mode, qos, mac, bond_mode, lacp, bond_updelay, bond_downdelay, bond_fake_iface, fake_bridge, status, statistics, other_config, external_ids
    }
    
    public init(name: String, interfaces: [String], trunks: [Int]? = nil, tag: Int? = nil, vlan_mode: String? = nil, qos: String? = nil, mac: String? = nil, bond_mode: String? = nil, lacp: String? = nil, bond_updelay: Int? = nil, bond_downdelay: Int? = nil, bond_fake_iface: Bool? = nil, fake_bridge: Bool? = nil, status: [String: String]? = nil, statistics: [String: Int]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.interfaces = interfaces
        self.trunks = trunks
        self.tag = tag
        self.vlan_mode = vlan_mode
        self.qos = qos
        self.mac = mac
        self.bond_mode = bond_mode
        self.lacp = lacp
        self.bond_updelay = bond_updelay
        self.bond_downdelay = bond_downdelay
        self.bond_fake_iface = bond_fake_iface
        self.fake_bridge = fake_bridge
        self.status = status
        self.statistics = statistics
        self.other_config = other_config
        self.external_ids = external_ids
    }
}