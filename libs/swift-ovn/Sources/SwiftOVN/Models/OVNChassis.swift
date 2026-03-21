import Foundation

public struct OVNChassis: Codable {
    public let uuid: String?
    public let name: String
    public let hostname: String
    public let encaps: [String]
    public let vtep_logical_switches: [String]?
    public let nb_cfg: Int?
    public let transport_zones: [String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, hostname, encaps, vtep_logical_switches, nb_cfg, transport_zones, other_config, external_ids
    }
}