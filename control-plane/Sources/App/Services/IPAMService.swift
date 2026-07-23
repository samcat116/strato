import Fluent
import Foundation
import SQLKit
import StratoShared

/// Control-plane IP address management: allocates static NIC addresses from a
/// `LogicalNetwork`'s subnet. The control plane is the IPAM owner (issue #212) —
/// agents receive allocations through the VM spec and never invent addresses.
///
/// Allocation strategy: lowest free host address, skipping the network address,
/// broadcast address, and gateway, with existing `VMNetworkInterface` rows on
/// the same network as the used set. Callers should run inside the same
/// transaction that saves the interface row; a per-network advisory lock
/// serializes concurrent allocations (VM and sandbox rows live in different
/// tables, so no unique index can span them), and each table's unique
/// `(network, address)` index backstops same-table races.
enum IPAMService {
    struct Allocation: Equatable {
        let ipAddress: String
        let netmask: String
        let prefixLength: Int
    }

    struct Allocation6: Equatable {
        /// Canonical (RFC 5952) address text.
        let ipAddress: String
        let prefixLength: Int
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

        /// Low-cardinality label for the allocation-failure metric.
        var metricReason: String {
            switch self {
            case .invalidSubnet: return "invalid_subnet"
            case .invalidGateway: return "invalid_gateway"
            case .poolExhausted: return "pool_exhausted"
            }
        }
    }

    /// Prefix lengths a network may allocate from. /31 and /32 have no host
    /// range; anything wider than /8 is no legitimate deployment and would make
    /// the exhaustion scan unreasonably large.
    static let allocatablePrefixRange = 8...30

    /// Takes a transaction-scoped advisory lock on the network so concurrent
    /// allocations serialize their read-allocate-insert cycle. The per-table
    /// `(network, address)` unique indexes only catch same-table races: a
    /// concurrent VM create and sandbox create insert into different tables,
    /// so neither hits a constraint and both could commit the same address.
    /// With the lock, the second allocator waits until the first transaction
    /// commits and then reads a used set that includes the winner's row.
    ///
    /// Postgres only: `pg_advisory_xact_lock` is held until the enclosing
    /// transaction ends, giving cross-replica serialization (see
    /// `QuotaEnforcementService.lockQuotas` for the same pattern). On SQLite
    /// (local tests) there is no advisory-lock primitive and writes already
    /// serialize on the database file, so this is a no-op.
    private static func lockAllocations(network: String, on db: Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: "ipam:\(network)")))").run()
    }

    /// Allocates the lowest free host address in `network`'s subnet.
    static func allocateIP(for network: LogicalNetwork, on db: Database) async throws -> Allocation {
        // The used set is the union of VM and sandbox addresses on the network
        // (issue #416): both draw from the same subnet, so an allocation must
        // see the other's addresses or two workloads could get the same IP.
        // Each table's own `(network, address)` unique index backstops
        // concurrent same-table creates; cross-table (VM vs sandbox) races
        // are serialized by the advisory lock, which no unique index covers.
        try await lockAllocations(network: network.name, on: db)
        let usedVM = try await VMInterfaceAddress.query(on: db)
            .filter(\.$network == network.name)
            .filter(\.$family == IPFamily.ipv4.rawValue)
            .all()
            .compactMap { parseIPv4($0.address) }
        let usedSandbox = try await SandboxInterfaceAddress.query(on: db)
            .filter(\.$network == network.name)
            .filter(\.$family == IPFamily.ipv4.rawValue)
            .all()
            .compactMap { parseIPv4($0.address) }
        let used = Set(usedVM).union(usedSandbox)

        do {
            let allocation = try allocateIP(
                networkName: network.name,
                subnet: network.subnet,
                gateway: network.gateway,
                used: used
            )
            Telemetry.ipamAllocated(family: "ipv4")
            return allocation
        } catch let error as IPAMError {
            Telemetry.ipamAllocationFailed(family: "ipv4", reason: error.metricReason)
            throw error
        }
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
            return Allocation(
                ipAddress: formatIPv4(candidate), netmask: formatIPv4(mask), prefixLength: prefix)
        }

        throw IPAMError.poolExhausted(network: networkName, subnet: subnet)
    }

    /// Allocates the next IPv6 address in `network`'s /64, or nil when the
    /// network is v4-only.
    static func allocateIPv6(for network: LogicalNetwork, on db: Database) async throws -> Allocation6? {
        guard let subnet6 = network.subnet6 else { return nil }
        // Union of VM and sandbox interface IDs on the network (issue #416),
        // for the same reason as the v4 path, under the same advisory lock.
        try await lockAllocations(network: network.name, on: db)
        let usedVM = try await VMInterfaceAddress.query(on: db)
            .filter(\.$network == network.name)
            .filter(\.$family == IPFamily.ipv6.rawValue)
            .all()
            .compactMap { IPv6Address($0.address)?.lo }
        let usedSandbox = try await SandboxInterfaceAddress.query(on: db)
            .filter(\.$network == network.name)
            .filter(\.$family == IPFamily.ipv6.rawValue)
            .all()
            .compactMap { IPv6Address($0.address)?.lo }

        do {
            let allocation = try allocateIPv6(
                networkName: network.name,
                subnet6: subnet6,
                gateway6: network.gateway6,
                usedInterfaceIDs: Set(usedVM).union(usedSandbox)
            )
            Telemetry.ipamAllocated(family: "ipv6")
            return allocation
        } catch let error as IPAMError {
            Telemetry.ipamAllocationFailed(family: "ipv6", reason: error.metricReason)
            throw error
        }
    }

    /// Pure IPv6 allocation core. A /64 has 2^64 hosts, so the v4 lowest-free
    /// linear scan cannot work; instead interface IDs are handed out
    /// sequentially past the highest one in use, starting at ::100 (keeping
    /// addresses short and recognizably control-plane-assigned). The database's
    /// unique (network, address) index is the backstop against concurrent
    /// creates — callers retry the enclosing transaction on a collision.
    static func allocateIPv6(
        networkName: String, subnet6: String, gateway6: String?, usedInterfaceIDs: Set<UInt64>
    ) throws -> Allocation6 {
        guard let cidr = IPv6CIDR(subnet6), cidr.prefix == 64 else {
            throw IPAMError.invalidSubnet(subnet6)
        }
        let base = cidr.networkAddress

        // Same rule as v4: a malformed gateway must fail loudly, or its real
        // address could be handed out to a VM.
        let gatewayID: UInt64?
        if let gateway6 {
            guard let parsed = IPv6Address(gateway6), cidr.contains(parsed) else {
                throw IPAMError.invalidGateway(gateway6)
            }
            gatewayID = parsed.lo
        } else {
            gatewayID = nil
        }

        var candidate = Swift.max(usedInterfaceIDs.max() ?? 0, 0xff)
        repeat {
            let (next, overflow) = candidate.addingReportingOverflow(1)
            guard !overflow else {
                // Unreachable in practice (2^64 interface IDs), but wraparound
                // must not mint the network address.
                throw IPAMError.poolExhausted(network: networkName, subnet: subnet6)
            }
            candidate = next
        } while candidate == gatewayID || usedInterfaceIDs.contains(candidate)

        return Allocation6(
            ipAddress: base.replacingInterfaceID(candidate).description, prefixLength: cidr.prefix)
    }

    /// Allocates the lowest free floating address in `pool`'s CIDR (issue
    /// #344). Same shape as NIC allocation: the used set is the pool's
    /// existing `FloatingIP` rows, a per-pool advisory lock serializes
    /// concurrent allocations, and the `(pool_id, address)` unique index
    /// backstops same-table races. Callers run inside the transaction that
    /// saves the new row.
    static func allocateFloatingIP(for pool: FloatingIPPool, on db: Database) async throws -> String {
        try await lockAllocations(network: "fip:\(pool.name)", on: db)
        let used = try await FloatingIP.query(on: db)
            .filter(\.$pool.$id == pool.requireID())
            .all()
            .compactMap { parseIPv4($0.address) }
        return try allocateIP(
            networkName: pool.name,
            subnet: pool.cidr,
            gateway: pool.gateway,
            used: Set(used)
        ).ipAddress
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

    // Thin wrappers over the StratoShared address types, kept for the many
    // existing call sites.

    static func parseCIDR(_ cidr: String) -> (base: UInt32, prefix: Int)? {
        guard let parsed = IPv4CIDR(cidr) else { return nil }
        return (parsed.base.raw, parsed.prefix)
    }

    static func parseIPv4(_ string: String) -> UInt32? {
        IPv4Address(string)?.raw
    }

    static func formatIPv4(_ value: UInt32) -> String {
        IPv4Address(raw: value).description
    }
}
