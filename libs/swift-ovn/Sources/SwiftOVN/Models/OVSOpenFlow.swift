import Foundation

public struct OVSOpenFlow: Codable {
    public let uuid: String?
    public let bridge: String
    public let version: [String]
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case bridge, version
    }
}