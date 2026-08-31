import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

/// Owns bounded command execution, address parsing, and DHCP option realization.
extension NetworkServiceLinux {
    #if os(Linux)
    // MARK: - Command Execution

    struct CommandResult {
        let status: Int32
        let output: String
    }

    /// Runs a command via `/usr/bin/env` (PATH resolution) and returns its exit
    /// status and combined stdout/stderr. Mirrors the `Process` usage in
    /// `FileSystemStorageBackend`.
    func runProcess(_ command: String, _ arguments: [String]) throws -> CommandResult {
        try runProcessAt("/usr/bin/env", [command] + arguments)
    }

    /// Runs an already-resolved executable, with no `PATH` lookup. The sandbox
    /// namespace path uses this: its binaries were located at agent start, and a
    /// stripped service-manager `PATH` must not be able to break a host the
    /// start-time probe declared usable.
    func runProcessAt(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    /// Runs a command and throws `NetworkError.tapError` on a non-zero exit,
    /// appending the remediation when the output points at a host problem
    /// (missing privileges) rather than a bad invocation.
    @discardableResult
    func run(_ command: String, _ arguments: [String]) throws -> String {
        let result = try runProcess(command, arguments)
        if result.status != 0 {
            throw NetworkError.tapError(networkCommandFailure(command, arguments, result))
        }
        return result.output
    }

    /// The failure message for a network command, with a remediation appended
    /// when the output points at a host problem rather than a bad invocation.
    func networkCommandFailure(
        _ command: String, _ arguments: [String], _ result: CommandResult
    ) -> String {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "`\(command) \(arguments.joined(separator: " "))` failed (exit \(result.status)): \(detail)"
        if detail.contains("Operation not permitted") || detail.contains("Permission denied") {
            message +=
                " — the agent needs root or CAP_NET_ADMIN to manage TAP devices and OVS ports; "
                + "run it as root or grant the capability (e.g. systemd AmbientCapabilities=CAP_NET_ADMIN)."
        }
        // The sandbox namespace path is the only user of clsact/matchall/mirred,
        // and a kernel without those modules fails here rather than at load time.
        if detail.contains("Unknown qdisc") || detail.contains("Specified filter type not supported")
            || detail.contains("Unknown action")
        {
            message +=
                " — sandbox NICs need the kernel's traffic-control modules (sch_clsact, cls_matchall, "
                + "act_mirred); install the distribution's extra/modules package for the running kernel."
        }
        return message
    }

    /// Returns true if a network interface with the given name exists.
    func tapDeviceExists(_ name: String) -> Bool {
        guard let result = try? runProcess("ip", ["link", "show", name]) else {
            return false
        }
        return result.status == 0
    }

    /// Parses an OVN logical switch port `addresses` entry (`"<mac> <ip>..."`
    /// with any number of per-family IPs, or just `"<mac>"`, or `"dynamic"`)
    /// into a MAC and its IP list. Both IPs of a dual-stack port must be
    /// recovered — dropping one on the re-attach path would silently strip
    /// that family from the port.
    static func parsePortAddress(_ addresses: [String]?) -> (mac: String, ips: [String]) {
        guard let first = addresses?.first(where: { !$0.isEmpty && $0.lowercased() != "dynamic" }) else {
            return ("", [])
        }
        let tokens = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let mac = tokens.first ?? ""
        return (mac, Array(tokens.dropFirst()))
    }

    func generateMACAddress() -> String {
        // Generate a random MAC address with the locally administered bit set
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        var macBytes = bytes
        macBytes[0] = (macBytes[0] & 0xFC) | 0x02  // Set locally administered bit

        return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Resolves the OVN `DHCP_Options` UUIDs a VM's port should bind to, per
    /// family. Nil when DHCP is disabled for the network or that family's
    /// subnet/gateway aren't known (OVN needs a CIDR and a server identity to
    /// answer). A nil member leaves the guest on the static cloud-init path
    /// for that family.
    func resolveDHCPOptions(for config: VMNetworkConfig) async throws -> (v4: String?, v6: String?) {
        guard config.dhcpEnabled else {
            // DHCP was turned off for the network: delete its managed
            // DHCP_Options rows. The port columns are weak refs in the OVN
            // schema, so the deletion clears the binding on every port of the
            // network at once — a port update cannot do it (the row encoder
            // omits nil fields, so nil can never overwrite a stale binding).
            try await removeDHCPOptions(networkId: config.networkId, networkName: config.networkName)
            return (nil, nil)
        }

        let v4: String?
        if let subnet = config.subnet, let gateway = config.gateway {
            v4 = try await ensureDHCPOptions(
                networkId: config.networkId, networkName: config.networkName, subnet: subnet,
                gateway: gateway,
                dnsServers: config.dnsServers, domainName: config.domainName, leaseTime: config.leaseTime,
                metadataEnabled: config.metadataEnabled, resolverAddresses: config.resolverAddresses)
        } else {
            logger.warning(
                "DHCP enabled but subnet/gateway unknown; using static guest config",
                metadata: ["network": .string(config.networkName)])
            v4 = nil
        }

        let v6: String?
        if let subnet6 = config.subnet6 {
            v6 = try await ensureDHCPOptions6(
                networkId: config.networkId, networkName: config.networkName, subnet6: subnet6,
                dnsServers: config.dnsServers, domainName: config.domainName,
                resolverAddresses: config.resolverAddresses)
        } else {
            v6 = nil
        }

        return (v4, v6)
    }

    /// Deletes every strato-managed `DHCP_Options` row stamped with this
    /// network's stable id (both families, and any stale-subnet leftovers).
    /// Matching by the external-id rather than CIDR means renumbered networks
    /// are cleaned up too, and rows other networks own are never touched.
    func removeDHCPOptions(networkId: UUID, networkName: String) async throws {
        guard let ovnManager else { return }
        let ownedID = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)[
            DHCPRowIdentity.networkIDKey]
        for row in try await ovnManager.getDHCPOptions() {
            // Rows this network owns at any CIDR.
            let owned =
                row.external_ids?[DHCPRowIdentity.managedKey] == DHCPRowIdentity.managedValue
                && row.external_ids?[DHCPRowIdentity.networkIDKey] == ownedID
            guard owned, let uuid = row.uuid else { continue }
            try await ovnManager.deleteDHCPOptions(uuid: uuid)
            logger.info(
                "Removed DHCP options for network with DHCP disabled",
                metadata: [
                    "network": .string(networkName),
                    "networkId": .string(networkId.uuidString),
                    "cidr": .string(row.cidr),
                ])
        }
    }

    /// This network's `DHCP_Options` row for `cidr`.
    static func ownDHCPRow(
        in rows: [OVNDHCPOptions], networkId: UUID, cidr: String
    ) -> OVNDHCPOptions? {
        rows.first(where: {
            DHCPRowIdentity.isOwn($0.external_ids, rowCIDR: $0.cidr, cidr: cidr, networkId: networkId)
        })
    }

    /// Find-or-update this network's `DHCP_Options` row for `subnet` and
    /// return its UUID. Idempotent across restarts and reconvergence: the
    /// network's existing row for the same CIDR is updated in place (so
    /// DNS/lease edits converge) rather than duplicated.
    ///
    /// `metadataEnabled` and `resolverEnabled` must be derived from the same
    /// `LogicalNetwork` columns on both callers — the NIC path reads
    /// `NetworkSpec.metadataEnabled`/`.resolverEnabled`, the network path
    /// `DesiredNetworkState`'s — or the two would author different option maps
    /// for one row and rewrite it on every pass.
    func ensureDHCPOptions(
        networkId: UUID, networkName: String, subnet: String, gateway: String,
        dnsServers: [String], domainName: String?, leaseTime: Int?, metadataEnabled: Bool,
        resolverAddresses: [String]
    ) async throws -> String? {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: gateway, dnsServers: dnsServers, domainName: domainName, leaseTime: leaseTime,
            subnet: subnet, metadataEnabled: metadataEnabled, resolverAddresses: resolverAddresses)
        let externalIDs = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)
        let dhcp = OVNDHCPOptions(cidr: subnet, options: options, external_ids: externalIDs)

        if let existing = Self.ownDHCPRow(
            in: try await ovnManager.getDHCPOptions(), networkId: networkId, cidr: subnet),
            let uuid = existing.uuid
        {
            // The external-ids are part of what converges, not just the
            // external ids: a renamed network needs its label refreshed.
            if existing.options != options || existing.external_ids != externalIDs {
                try await ovnManager.updateDHCPOptions(uuid: uuid, dhcp)
            }
            return uuid
        }
        return try await ovnManager.createDHCPOptions(dhcp)
    }

    /// The DHCPv6 sibling of `ensureDHCPOptions`. OVN keys the DHCP family
    /// off the `DHCP_Options` row's CIDR — an IPv6 CIDR makes it a DHCPv6
    /// row — so the mechanics are identical; only the option grammar differs
    /// (see `OVNDHCPOptionsBuilder.v6Options`).
    func ensureDHCPOptions6(
        networkId: UUID, networkName: String, subnet6: String, dnsServers: [String],
        domainName: String?, resolverAddresses: [String]
    ) async throws -> String? {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let options = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: dnsServers, domainName: domainName, subnet6: subnet6,
            resolverAddresses: resolverAddresses)
        let externalIDs = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)
        let dhcp = OVNDHCPOptions(cidr: subnet6, options: options, external_ids: externalIDs)

        if let existing = Self.ownDHCPRow(
            in: try await ovnManager.getDHCPOptions(), networkId: networkId, cidr: subnet6),
            let uuid = existing.uuid
        {
            if existing.options != options || existing.external_ids != externalIDs {
                try await ovnManager.updateDHCPOptions(uuid: uuid, dhcp)
            }
            return uuid
        }
        return try await ovnManager.createDHCPOptions(dhcp)
    }
    #endif
}
