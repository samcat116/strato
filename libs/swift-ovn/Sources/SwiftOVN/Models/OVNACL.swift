import Foundation

public struct OVNACL: Codable {
    public let uuid: String?
    public let priority: Int
    public let direction: String
    public let match: String
    public let action: String
    public let log: Bool?
    public let severity: String?
    public let meter: String?
    public let name: String?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case priority, direction, match, action, log, severity, meter, name, external_ids
    }
    
    public init(priority: Int, direction: String, match: String, action: String, log: Bool? = nil, severity: String? = nil, meter: String? = nil, name: String? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.priority = priority
        self.direction = direction
        self.match = match
        self.action = action
        self.log = log
        self.severity = severity
        self.meter = meter
        self.name = name
        self.external_ids = external_ids
    }
}