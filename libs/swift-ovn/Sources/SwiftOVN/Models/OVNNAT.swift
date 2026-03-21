import Foundation

public struct OVNNAT: Codable {
    public let uuid: String?
    public let natType: String
    public let external_ip: String
    public let external_mac: String?
    public let external_port_range: String?
    public let logical_ip: String
    public let logical_port: String?
    public let allowed_ext_ips: String?
    public let exempted_ext_ips: String?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case external_ip, external_mac, external_port_range, logical_ip, logical_port, allowed_ext_ips, exempted_ext_ips, options, external_ids
        case natType = "type"
    }
    
    public init(natType: String, external_ip: String, logical_ip: String, external_mac: String? = nil, external_port_range: String? = nil, logical_port: String? = nil, allowed_ext_ips: String? = nil, exempted_ext_ips: String? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.natType = natType
        self.external_ip = external_ip
        self.external_mac = external_mac
        self.external_port_range = external_port_range
        self.logical_ip = logical_ip
        self.logical_port = logical_port
        self.allowed_ext_ips = allowed_ext_ips
        self.exempted_ext_ips = exempted_ext_ips
        self.options = options
        self.external_ids = external_ids
    }
}