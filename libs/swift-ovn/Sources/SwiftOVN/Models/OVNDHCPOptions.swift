import Foundation

public struct OVNDHCPOptions: Codable {
    public let uuid: String?
    public let cidr: String
    public let options: [String: String]
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case cidr, options, external_ids
    }
    
    public init(cidr: String, options: [String: String], external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.cidr = cidr
        self.options = options
        self.external_ids = external_ids
    }
}