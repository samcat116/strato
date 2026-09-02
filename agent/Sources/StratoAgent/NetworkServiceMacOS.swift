import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// macOS network service implementation using user-mode (SLIRP) networking
/// OVN/OVS are not supported on macOS, so we use QEMU's built-in user-mode networking
actor NetworkServiceMacOS: NetworkServiceProtocol {
    private let logger: Logger
    private let maxMACGenerationAttempts = 100

    private var usedMACs: Set<String> = []
    private var lastObservedLoadBalancers: [ObservedLoadBalancerState]?

    init(logger: Logger) {
        self.logger = logger
        logger.info("Network service initialized with user-mode (SLIRP) networking for macOS")
    }

    // MARK: - Connection Management

    func connect() async throws {
        logger.info("User-mode network service ready (no external service required)")
    }

    func disconnect() async {
        logger.info("User-mode network service disconnected")
    }

    // MARK: - VM Network Lifecycle

    /// `placement` is accepted for protocol conformance and ignored: user-mode
    /// SLIRP creates nothing on the host, so there is no device to put in a
    /// namespace.
    ///
    /// Despite the name this service is **not** macOS-only — `Agent.start()`
    /// builds it for `network_mode = "user"` on every platform. So a jailed
    /// Linux agent in user mode *can* reach here with a sandbox placement, and
    /// gets `.userMode` back. That attachment cannot be realized by a jailed
    /// Firecracker (its only backend is a TAP opened by name), which is why the
    /// sandbox runtime refuses a non-TAP attachment rather than dropping it.
    func createVMNetwork(
        vmId: String, nicIndex: Int, config: VMNetworkConfig, placement: NICPlacement
    ) async throws -> VMNetworkInfo {
        logger.info(
            "Creating VM network with user-mode networking",
            metadata: ["strato.vm.id": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        let macAddress: String
        if let configuredMAC = config.macAddress {
            guard let parsedMAC = MACAddress(configuredMAC) else {
                throw NetworkError.invalidConfiguration(
                    "MAC address '\(configuredMAC)' is not a six-octet unicast address")
            }
            macAddress = parsedMAC.description
        } else {
            macAddress = generateMACAddress()
        }

        // User-mode networking provides automatic DHCP: VMs get addresses in the
        // 10.0.2.0/24 range from QEMU's SLIRP, so no IP is allocated (or honored)
        // here — reporting one would just be fiction.
        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: "user-\(vmId)-\(nicIndex)",
            portUUID: nil,
            attachment: .userMode,
            macAddress: macAddress,
            ipAddress: nil
        )

        logger.info(
            "VM network created with user-mode networking",
            metadata: [
                "strato.vm.id": .string(vmId),
                "macAddress": .string(macAddress),
            ])

        return networkInfo
    }

    func detachVMFromNetwork(vmId: String, nicIndex: Int, placement: NICPlacement) async throws {
        logger.info(
            "Detaching VM from user-mode network",
            metadata: ["strato.vm.id": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])
    }

    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?, resolverNetworks: [ResolverNetworkConfig]?,
        dnsZones: [DesiredDNSZone]?
    ) async {
        guard authoritative else {
            lastObservedLoadBalancers = nil
            return
        }
        let reason = "Native OVN load balancers are not supported with user-mode networking"
        let desired = networks.flatMap(\.loadBalancers)
        if !desired.isEmpty {
            logger.error("\(reason)")
        }
        lastObservedLoadBalancers = desired.map {
            ObservedLoadBalancerState(
                id: $0.id,
                observedGeneration: $0.generation,
                status: .error,
                lastError: reason,
                backends: $0.backends.map {
                    ObservedLoadBalancerBackend(id: $0.id, healthStatus: .error)
                })
        }
    }

    func observedLoadBalancers() async -> [ObservedLoadBalancerState]? {
        lastObservedLoadBalancers
    }

    private func generateMACAddress() -> String {
        // Use QEMU's OUI (52:54:00) for better compatibility
        var macAddress: String
        var attempts = 0

        repeat {
            let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
            macAddress = "52:54:00:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            attempts += 1

            if attempts > maxMACGenerationAttempts {
                // Fallback to deterministic MAC if we can't find a unique one
                let timestamp = UInt32(Date().timeIntervalSince1970)
                macAddress = String(
                    format: "52:54:00:%02x:%02x:%02x",
                    UInt8(timestamp >> 16 & 0xFF),
                    UInt8(timestamp >> 8 & 0xFF),
                    UInt8(timestamp & 0xFF))
                break
            }
        } while usedMACs.contains(macAddress)

        usedMACs.insert(macAddress)
        return macAddress
    }
}
