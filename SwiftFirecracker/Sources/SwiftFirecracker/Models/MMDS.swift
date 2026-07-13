import Foundation

/// MicroVM Metadata Service (MMDS) configuration.
/// Maps to the `PUT /mmds/config` API endpoint.
///
/// MMDS is an alternative host→guest channel: the guest reads a metadata store
/// (set via `PUT /mmds`) over an HTTP endpoint at `ipv4Address`. Only the
/// network interfaces named in `networkInterfaces` are allowed to route to it,
/// which is the successor to the removed per-interface `allow_mmds_requests`
/// flag.
public struct MMDSConfig: Codable, Sendable {
    /// MMDS version: "V1" or "V2". V2 requires a session token and is the
    /// recommended default.
    public let version: String?

    /// IDs of the network interfaces (matching `NetworkInterface.ifaceId`)
    /// permitted to reach the MMDS endpoint.
    public let networkInterfaces: [String]

    /// IPv4 address the guest uses to reach MMDS. Defaults to Firecracker's
    /// `169.254.169.254` when omitted.
    public let ipv4Address: String?

    enum CodingKeys: String, CodingKey {
        case version
        case networkInterfaces = "network_interfaces"
        case ipv4Address = "ipv4_address"
    }

    public init(
        version: MMDSVersion? = nil,
        networkInterfaces: [String],
        ipv4Address: String? = nil
    ) {
        self.version = version?.rawValue
        self.networkInterfaces = networkInterfaces
        self.ipv4Address = ipv4Address
    }
}

/// Supported MMDS versions for ``MMDSConfig``.
public enum MMDSVersion: String, Sendable {
    case v1 = "V1"
    case v2 = "V2"
}
