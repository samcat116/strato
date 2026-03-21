import Foundation

public struct OVNLogicalRouter: Codable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let static_routes: [String]?
    public let policies: [String]?
    public let nat: [String]?
    public let load_balancer: [String]?
    public let enabled: Bool?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports, static_routes, policies, nat, load_balancer, enabled, options, external_ids
    }
    
    public init(name: String, ports: [String]? = nil, static_routes: [String]? = nil, policies: [String]? = nil, nat: [String]? = nil, load_balancer: [String]? = nil, enabled: Bool? = true, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.static_routes = static_routes
        self.policies = policies
        self.nat = nat
        self.load_balancer = load_balancer
        self.enabled = enabled
        self.options = options
        self.external_ids = external_ids
    }
}