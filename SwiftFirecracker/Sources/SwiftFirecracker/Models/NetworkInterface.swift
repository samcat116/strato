import Foundation

/// Network interface configuration
/// Maps to PUT /network-interfaces/{iface_id} API endpoint
public struct NetworkInterface: Codable, Sendable {
    /// Unique identifier for the network interface
    public let ifaceId: String

    /// Name of the TAP device on the host
    public let hostDevName: String

    /// MAC address for the guest interface (optional, auto-generated if not provided)
    public let guestMac: String?

    /// Rate limiter for receive traffic
    public let rxRateLimiter: RateLimiter?

    /// Rate limiter for transmit traffic
    public let txRateLimiter: RateLimiter?

    enum CodingKeys: String, CodingKey {
        case ifaceId = "iface_id"
        case hostDevName = "host_dev_name"
        case guestMac = "guest_mac"
        case rxRateLimiter = "rx_rate_limiter"
        case txRateLimiter = "tx_rate_limiter"
    }

    public init(
        ifaceId: String,
        hostDevName: String,
        guestMac: String? = nil,
        rxRateLimiter: RateLimiter? = nil,
        txRateLimiter: RateLimiter? = nil
    ) {
        self.ifaceId = ifaceId
        self.hostDevName = hostDevName
        self.guestMac = guestMac
        self.rxRateLimiter = rxRateLimiter
        self.txRateLimiter = txRateLimiter
    }

    /// Creates a network interface with a TAP device
    public static func tap(
        id: String = "eth0",
        tapName: String,
        macAddress: String? = nil
    ) -> NetworkInterface {
        NetworkInterface(
            ifaceId: id,
            hostDevName: tapName,
            guestMac: macAddress
        )
    }
}
