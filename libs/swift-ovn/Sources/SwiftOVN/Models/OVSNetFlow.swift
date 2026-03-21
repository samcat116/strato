import Foundation

public struct OVSNetFlow: Codable {
    public let uuid: String?
    public let targets: [String]
    public let engine_type: Int?
    public let engine_id: Int?
    public let add_id_to_interface: Bool?
    public let active_timeout: Int?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case targets, engine_type, engine_id, add_id_to_interface, active_timeout, external_ids
    }
    
    public init(targets: [String], engine_type: Int? = nil, engine_id: Int? = nil, add_id_to_interface: Bool? = nil, active_timeout: Int? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.targets = targets
        self.engine_type = engine_type
        self.engine_id = engine_id
        self.add_id_to_interface = add_id_to_interface
        self.active_timeout = active_timeout
        self.external_ids = external_ids
    }
}