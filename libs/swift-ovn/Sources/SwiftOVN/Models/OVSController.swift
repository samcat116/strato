import Foundation

public struct OVSController: Codable {
    public let uuid: String?
    public let target: String
    public let max_backoff: Int?
    public let inactivity_probe: Int?
    public let connection_mode: String?
    public let enable_async_messages: Bool?
    public let controller_rate_limit: Int?
    public let controller_burst_limit: Int?
    public let local_ip: String?
    public let local_netmask: String?
    public let local_gateway: String?
    public let status: [String: String]?
    public let role: String?
    public let external_ids: [String: String]?
    public let other_config: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case target, max_backoff, inactivity_probe, connection_mode, enable_async_messages, controller_rate_limit, controller_burst_limit, local_ip, local_netmask, local_gateway, status, role, external_ids, other_config
    }
    
    public init(target: String, max_backoff: Int? = nil, inactivity_probe: Int? = nil, connection_mode: String? = nil, enable_async_messages: Bool? = nil, controller_rate_limit: Int? = nil, controller_burst_limit: Int? = nil, local_ip: String? = nil, local_netmask: String? = nil, local_gateway: String? = nil, status: [String: String]? = nil, role: String? = nil, external_ids: [String: String]? = nil, other_config: [String: String]? = nil) {
        self.uuid = nil
        self.target = target
        self.max_backoff = max_backoff
        self.inactivity_probe = inactivity_probe
        self.connection_mode = connection_mode
        self.enable_async_messages = enable_async_messages
        self.controller_rate_limit = controller_rate_limit
        self.controller_burst_limit = controller_burst_limit
        self.local_ip = local_ip
        self.local_netmask = local_netmask
        self.local_gateway = local_gateway
        self.status = status
        self.role = role
        self.external_ids = external_ids
        self.other_config = other_config
    }
}