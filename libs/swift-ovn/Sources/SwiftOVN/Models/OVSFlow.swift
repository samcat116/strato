import Foundation

public struct OVSFlow: Codable {
    public let table: Int?
    public let priority: Int?
    public let match: String?
    public let actions: String?
    public let idle_timeout: Int?
    public let hard_timeout: Int?
    public let cookie: String?
    public let packet_count: Int?
    public let byte_count: Int?
    public let duration: String?
    
    public init(table: Int? = nil, priority: Int? = nil, match: String? = nil, actions: String? = nil, idle_timeout: Int? = nil, hard_timeout: Int? = nil, cookie: String? = nil, packet_count: Int? = nil, byte_count: Int? = nil, duration: String? = nil) {
        self.table = table
        self.priority = priority
        self.match = match
        self.actions = actions
        self.idle_timeout = idle_timeout
        self.hard_timeout = hard_timeout
        self.cookie = cookie
        self.packet_count = packet_count
        self.byte_count = byte_count
        self.duration = duration
    }
}