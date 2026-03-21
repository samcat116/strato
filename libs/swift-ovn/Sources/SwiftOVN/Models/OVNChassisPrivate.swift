import Foundation

public struct OVNChassisPrivate: Codable {
    public let uuid: String?
    public let name: String
    public let chassis: String?
    public let nb_cfg: Int?
    public let nb_cfg_timestamp: Int?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, chassis, nb_cfg, nb_cfg_timestamp, external_ids
    }
}