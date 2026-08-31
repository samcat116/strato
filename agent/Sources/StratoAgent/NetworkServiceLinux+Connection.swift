import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

/// Owns OVN and OVS connection lifecycle and dependency health.
extension NetworkServiceLinux {
    // MARK: - Connection Management

    func connect() async throws {
        #if os(Linux)
        logger.info("Connecting to OVN/OVS services")

        // Initialize OVN manager. The string form can't express TLS options
        // (CA, client cert), so an ssl: endpoint is re-created with the
        // configured material when the operator supplied any.
        var nbEndpoint = try OVSDBEndpoint(parsing: ovnNBConnection)
        if case .ssl(let host, let port, _) = nbEndpoint, let tls = ovnNBTLS {
            nbEndpoint = .ssl(
                host: host, port: port,
                tls: OVSDBTLSConfiguration(
                    caCertificatePath: tls.caCertPath,
                    clientCertificatePath: tls.clientCertPath,
                    clientPrivateKeyPath: tls.clientKeyPath,
                    verifiesServerCertificate: tls.verifyServerCertificate,
                    serverHostname: tls.serverHostname
                ))
        }
        ovnManager = OVNManager(endpoint: nbEndpoint, logger: logger)
        try await ovnManager?.connect()
        logger.info("Connected to OVN database", metadata: ["endpoint": .string(ovnNBConnection)])

        // Initialize OVS manager
        ovsManager = OVSManager(socketPath: ovsSocketPath, logger: logger)
        try await ovsManager?.connect()
        logger.info("Connected to OVS database", metadata: ["socket": .string(ovsSocketPath)])

        // Ensure integration bridge exists
        try await ensureIntegrationBridge()

        // Ensure the chassis is registered with OVN (ovn-remote/encap
        // external_ids), then prove ovn-controller actually connected — a
        // chassis that never registers means ports get created but no flows
        // are ever programmed, which must gate the capability, not pass
        // silently (issue #328).
        try ensureChassisConfiguration()
        try await verifyOVNControllerConnected()

        // Service_Monitor lives in Southbound. Keep this connection separate
        // from the single-writer NB manager and do not make basic networking
        // unavailable if the operator's SB RBAC permits ovn-controller but not
        // this read — health observation will report a backend error until the
        // access is fixed.
        do {
            let connection = try southboundConnectionString()
            var endpoint = try OVSDBEndpoint(parsing: connection)
            if case .ssl(let host, let port, _) = endpoint, let tls = ovnNBTLS {
                endpoint = .ssl(
                    host: host, port: port,
                    tls: OVSDBTLSConfiguration(
                        caCertificatePath: tls.caCertPath,
                        clientCertificatePath: tls.clientCertPath,
                        clientPrivateKeyPath: tls.clientKeyPath,
                        verifiesServerCertificate: tls.verifyServerCertificate,
                        serverHostname: tls.serverHostname))
            }
            let manager = OVNManager(
                endpoint: endpoint, database: OVNDatabase.southbound, logger: logger)
            try await manager.connect()
            ovnSouthboundManager = manager
            logger.info(
                "Connected to OVN Southbound database for load-balancer health",
                metadata: ["endpoint": .string(connection)])
        } catch {
            ovnSouthboundManager = nil
            logger.error(
                "Cannot connect to OVN Southbound database; native LB health will report an error",
                metadata: ["error": .string(error.localizedDescription)])
        }

        isConnected = true
        logger.info("Network service connected successfully")
        #else
        logger.info("Mock network service connected (development mode)")
        #endif
    }

    func disconnect() async {
        #if os(Linux)
        logger.info("Disconnecting from OVN/OVS services")

        do {
            try await ovnManager?.disconnect()
            try await ovnSouthboundManager?.disconnect()
            try await ovsManager?.disconnect()
        } catch {
            logger.error("Error disconnecting from OVN/OVS: \(error)")
        }

        ovnManager = nil
        ovnSouthboundManager = nil
        ovsManager = nil
        isConnected = false

        logger.info("Network service disconnected")
        #else
        logger.info("Mock network service disconnected (development mode)")
        #endif
    }

    /// Proves the dataplane prerequisites without changing host state: the
    /// configured NB accepts a transaction, local OVSDB still contains
    /// `br-int`, chassis metadata matches the desired configuration, and
    /// ovn-controller remains connected to SB.
    func inspectDependencyHealth() async -> NetworkDependencyHealth {
        #if os(Linux)
        guard isConnected, let ovnManager, let ovsManager else {
            return .unhealthy("OVN/OVS database clients are not connected")
        }

        do {
            // A lookup for an impossible Strato-owned name is still a complete
            // read transaction and has no side effect when it returns nil.
            _ = try await ovnManager.getLogicalSwitch(named: "__strato_dependency_health__")
            guard try await ovsManager.getBridge(named: Self.ovnIntegrationBridge) != nil else {
                return .unhealthy("OVS integration bridge br-int is missing")
            }
        } catch {
            return .unhealthy("OVN/OVS database health query failed: \(error.localizedDescription)")
        }

        let chassisHealth = await inspectChassisConfiguration()
        guard chassisHealth.state == .healthy else { return chassisHealth }

        let toolSearchPath =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        guard let appctl = HostPreflight.locateTool("ovn-appctl", searchPath: toolSearchPath) else {
            return .advisory(
                "ovn-appctl is missing; ovn-controller connection status cannot be verified",
                code: .missingBinary)
        }
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: appctl),
                arguments: ["-t", "ovn-controller", "connection-status"],
                timeout: .seconds(5))
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.terminationStatus == 0, output == "connected" else {
                return .unhealthy(
                    "ovn-controller is not connected to SB (\(output.isEmpty ? "no status" : output))")
            }
        } catch is ProcessTimedOutError {
            return .unhealthy("ovn-controller connection probe timed out", code: .commandTimedOut)
        } catch {
            return .unhealthy("ovn-controller connection probe failed: \(error.localizedDescription)")
        }
        return .healthy
        #else
        return .healthy
        #endif
    }

    func inspectChassisConfiguration() async -> NetworkDependencyHealth {
        guard chassisConfig.bootstrapEnabled else { return .healthy }

        let candidates = [
            "/usr/bin/ovs-vsctl", "/usr/sbin/ovs-vsctl", "/usr/local/bin/ovs-vsctl",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .unhealthy("ovs-vsctl is missing", code: .missingBinary)
        }
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: ["--timeout=5", "get", "open_vswitch", ".", "external_ids"],
                timeout: .seconds(5),
                maxOutputBytes: 16 * 1024)
            guard result.terminationStatus == 0 else {
                return .unhealthy(
                    "cannot read chassis external_ids: "
                        + result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let existing = OVNChassisBootstrap.parseExternalIDs(result.combinedOutput)
            let plan = OVNChassisBootstrap.plan(
                config: chassisConfig,
                existing: existing,
                detectedEncapIP: nil,
                generatedSystemID: "dependency-health-probe")
            guard plan.settings.isEmpty, !plan.encapIPUnresolved else {
                let missingOrDrifted = plan.settings.map(\.key).joined(separator: ", ")
                let detail = missingOrDrifted.isEmpty ? "ovn-encap-ip" : missingOrDrifted
                return .unhealthy("OVN chassis external_ids are missing or drifted: \(detail)")
            }
            return .healthy
        } catch is ProcessTimedOutError {
            return .unhealthy("OVN chassis configuration probe timed out", code: .commandTimedOut)
        } catch {
            return .unhealthy("OVN chassis configuration probe failed: \(error.localizedDescription)")
        }
    }

    #if os(Linux)
    func southboundConnectionString() throws -> String {
        if let configured = chassisConfig.remote, !configured.isEmpty {
            return configured
        }
        let result = try runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        guard result.status == 0 else {
            throw NetworkError.ovsError(
                "cannot read chassis external_ids for the Southbound endpoint (exit \(result.status))")
        }
        return OVNChassisBootstrap.parseExternalIDs(result.output)["ovn-remote"]
            ?? OVNChassisBootstrap.defaultRemote
    }
    #endif
}
