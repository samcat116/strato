import Fluent
import Foundation

/// Control-plane IP address management: allocates static NIC addresses from a
/// `LogicalNetwork`'s subnet. The control plane is the IPAM owner (issue #212) —
/// agents receive allocations through the VM spec and never invent addresses.
///
/// Allocation strategy: lowest free host address, skipping the network address,
/// broadcast address, and gateway, with existing `VMNetworkInterface` rows on
/// the same network as the used set. Callers should run inside the same
/// transaction that saves the interface row; the unique `(network, ip_address)`
/// index is the backstop against concurrent creates racing to the same address.
enum IPAMService {
    struct Allocation: Equatable {
        let ipAddress: String
        let netmask: String
    }

    enum IPAMError: Error, LocalizedError, Equatable {
        case invalidSubnet(String)
        case invalidGateway(String)
        case poolExhausted(network: String, subnet: String)

        var errorDescription: String? {
            switch self {
            case .invalidSubnet(let subnet):
                return "Logical network has an invalid subnet: \(subnet)"
            case .invalidGateway(let gateway):
                return "Logical network has an invalid gateway: \(gateway)"
            case .poolExhausted(let network, let subnet):
                return "No free IP addresses left in network \(network) (\(subnet))"
            }
        }
    }

    /// Prefix lengths a network may allocate from. /31 and /32 have no host
    /// range; anything wider than /8 is no legitimate deployment and would make
    /// the exhaustion scan unreasonably large.
    static let allocatablePrefixRange = 8...30

    /// Allocates the lowest free host address in `network`'s subnet.
    static func allocateIP(for network: LogicalNetwork, on db: Database) async throws -> Allocation {
        let used = try await VMNetworkInterface.query(on: db)
            .filter(\.$network == network.name)
            .all()
            .compactMap { $0.ipAddress.flatMap(parseIPv4) }

        return try allocateIP(
            networkName: network.name,
            subnet: network.subnet,
            gateway: network.gateway,
            used: Set(used)
        )
    }

    /// Pure allocation core, separated for testability.
    static func allocateIP(
        networkName: String, subnet: String, gateway: String?, used: Set<UInt32>
    ) throws -> Allocation {
        guard let (base, prefix) = parseCIDR(subnet), allocatablePrefixRange.contains(prefix) else {
            throw IPAMError.invalidSubnet(subnet)
        }

        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        let networkAddress = base & mask
        let broadcastAddress = networkAddress | ~mask

        // A malformed gateway must fail loudly: silently treating it as absent
        // would hand the gateway's real address out to a VM.
        let gatewayValue: UInt32?
        if let gateway {
            guard let parsed = parseIPv4(gateway) else {
                throw IPAMError.invalidGateway(gateway)
            }
            gatewayValue = parsed
        } else {
            gatewayValue = nil
        }

        for candidate in (networkAddress + 1)..<broadcastAddress {
            if candidate == gatewayValue { continue }
            if used.contains(candidate) { continue }
            return Allocation(ipAddress: formatIPv4(candidate), netmask: formatIPv4(mask))
        }

        throw IPAMError.poolExhausted(network: networkName, subnet: subnet)
    }

    /// The first host address of a subnet (conventionally the gateway), e.g.
    /// "192.168.1.0/24" → "192.168.1.1". Used when seeding networks without an
    /// explicit gateway.
    static func firstHostAddress(inSubnet subnet: String) -> String? {
        guard let (base, prefix) = parseCIDR(subnet), allocatablePrefixRange.contains(prefix) else { return nil }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        return formatIPv4((base & mask) + 1)
    }

    // MARK: - IPv4 helpers

    static func parseCIDR(_ cidr: String) -> (base: UInt32, prefix: Int)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
            let base = parseIPv4(String(parts[0])),
            let prefix = Int(parts[1]),
            (0...32).contains(prefix)
        else {
            return nil
        }
        return (base, prefix)
    }

    static func parseIPv4(_ string: String) -> UInt32? {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    static func formatIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xff).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
    }
}
