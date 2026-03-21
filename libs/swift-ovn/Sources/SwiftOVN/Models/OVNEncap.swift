import Foundation

public struct OVNEncap: Codable {
    public let uuid: String?
    public let encapType: String
    public let ip: String
    public let options: [String: String]?
    public let chassis_name: String?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case ip, options, chassis_name
        case encapType = "type"
    }
}