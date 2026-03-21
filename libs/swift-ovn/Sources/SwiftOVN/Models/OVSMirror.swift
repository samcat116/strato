import Foundation

public struct OVSMirror: Codable {
    public let uuid: String?
    public let name: String
    public let select_all: Bool?
    public let select_src_port: [String]?
    public let select_dst_port: [String]?
    public let select_vlan: [Int]?
    public let output_port: String?
    public let output_vlan: Int?
    public let snaplen: Int?
    public let external_ids: [String: String]?
    public let statistics: [String: Int]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, select_all, select_src_port, select_dst_port, select_vlan, output_port, output_vlan, snaplen, external_ids, statistics
    }
    
    public init(name: String, select_all: Bool? = nil, select_src_port: [String]? = nil, select_dst_port: [String]? = nil, select_vlan: [Int]? = nil, output_port: String? = nil, output_vlan: Int? = nil, snaplen: Int? = nil, external_ids: [String: String]? = nil, statistics: [String: Int]? = nil) {
        self.uuid = nil
        self.name = name
        self.select_all = select_all
        self.select_src_port = select_src_port
        self.select_dst_port = select_dst_port
        self.select_vlan = select_vlan
        self.output_port = output_port
        self.output_vlan = output_vlan
        self.snaplen = snaplen
        self.external_ids = external_ids
        self.statistics = statistics
    }
}