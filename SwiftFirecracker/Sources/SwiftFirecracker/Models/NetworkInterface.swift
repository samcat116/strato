import Foundation

/// Network interface configuration
/// Maps to PUT /network-interfaces/{iface_id} API endpoint
public struct NetworkInterface: Codable, Sendable {
    /// Unique identifier for the network interface
    let ifaceId: String

    /// Name of the TAP device on the host
    let hostDevName: String

    /// MAC address for the guest interface (optional, auto-generated if not provided)
    let guestMac: String?

    enum CodingKeys: String, CodingKey {
        case ifaceId = "iface_id"
        case hostDevName = "host_dev_name"
        case guestMac = "guest_mac"
    }

    private init(
        ifaceId: String,
        hostDevName: String,
        guestMac: String? = nil
    ) {
        self.ifaceId = ifaceId
        self.hostDevName = hostDevName
        self.guestMac = guestMac
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
