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
        guard !disconnecting else { throw CancellationError() }
        if isConnected { return }

        let task: Task<Void, any Error>
        if let connecting {
            task = connecting
        } else {
            task = Task {
                try await ConnectionDeadline.run(
                    timeout: .seconds(30),
                    connect: { try await self.establishConnection() },
                    interrupt: { await self.disconnectManagers() })
            }
            connecting = task
        }

        do {
            try await task.value
            guard !disconnecting, !Task.isCancelled else { throw CancellationError() }
            if connecting == task {
                connecting = nil
                isConnected = true
            }
            guard isConnected else { throw CancellationError() }
        } catch {
            if connecting == task { connecting = nil }
            throw error
        }
        #else
        logger.info("Mock network service connected (development mode)")
        #endif
    }

    #if os(Linux)
    private func establishConnection() async throws {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        logger.info("Connected to OVN database", metadata: ["endpoint": .string(ovnNBConnection)])

        // Initialize OVS manager
        ovsManager = OVSManager(socketPath: ovsSocketPath, logger: logger)
        try await ovsManager?.connect()
        try Task.checkCancellation()
        logger.info("Connected to OVS database", metadata: ["socket": .string(ovsSocketPath)])

        // Ensure integration bridge exists
        try await ensureIntegrationBridge()
        try Task.checkCancellation()

        // Ensure the chassis is registered with OVN (ovn-remote/encap
        // external_ids), then prove ovn-controller actually connected — a
        // chassis that never registers means ports get created but no flows
        // are ever programmed, which must gate the capability, not pass
        // silently (issue #328).
        try await ensureChassisConfiguration()
        try Task.checkCancellation()
        try await verifyOVNControllerConnected()
        try Task.checkCancellation()

        logger.info("Network service connected successfully")
    }
    #endif

    func disconnect() async {
        #if os(Linux)
        logger.info("Disconnecting from OVN/OVS services")
        disconnecting = true
        isConnected = false
        let attempt = connecting
        let healthAttempt = southboundConnecting
        attempt?.cancel()
        healthAttempt?.cancel()
        await disconnectManagers()
        _ = await attempt?.result
        _ = await healthAttempt?.result
        connecting = nil
        southboundConnecting = nil
        southboundRetryAfter = nil
        disconnecting = false

        logger.info("Network service disconnected")
        #else
        logger.info("Mock network service disconnected (development mode)")
        #endif
    }

    #if os(Linux)
    private func disconnectManagers() async {
        // Release every transport even if a peer's close fails. These local
        // references belong to this attempt and cannot close a later retry.
        let northbound = ovnManager
        let southbound = ovnSouthboundManager
        let ovs = ovsManager
        ovnManager = nil
        ovnSouthboundManager = nil
        ovsManager = nil
        do { try await northbound?.disconnect() } catch { logger.warning("Could not close OVN Northbound: \(error)") }
        do { try await southbound?.disconnect() } catch { logger.warning("Could not close OVN Southbound: \(error)") }
        do { try await ovs?.disconnect() } catch { logger.warning("Could not close OVS: \(error)") }
    }

    /// Health is optional and recovers on a later observation without taking
    /// ordinary networking down. Concurrent LB observations share one attempt.
    func ensureSouthboundConnection() async throws {
        guard isConnected, !disconnecting else {
            throw NetworkError.notConnected("OVN networking is not connected")
        }
        if let southboundConnecting { return try await southboundConnecting.value }
        if ovnSouthboundManager != nil { return }
        if let retryAfter = southboundRetryAfter, ContinuousClock.now < retryAfter {
            throw NetworkError.notConnected("OVN Southbound connection is waiting to retry")
        }
        let task = Task {
            let connection = try await self.southboundConnectionString()
            try Task.checkCancellation()
            var endpoint = try OVSDBEndpoint(parsing: connection)
            if case .ssl(let host, let port, _) = endpoint, let tls = self.ovnNBTLS {
                endpoint = .ssl(
                    host: host, port: port,
                    tls: OVSDBTLSConfiguration(
                        caCertificatePath: tls.caCertPath, clientCertificatePath: tls.clientCertPath,
                        clientPrivateKeyPath: tls.clientKeyPath,
                        verifiesServerCertificate: tls.verifyServerCertificate,
                        serverHostname: tls.serverHostname))
            }
            let manager = OVNManager(endpoint: endpoint, database: OVNDatabase.southbound, logger: self.logger)
            try await ConnectionDeadline.run(
                timeout: .seconds(10), connect: { try await manager.connect() },
                interrupt: { try? await manager.disconnect() })
            // Publish only after the attempt is complete and still wanted.
            guard !Task.isCancelled, !self.disconnecting else {
                try? await manager.disconnect()
                throw CancellationError()
            }
            self.ovnSouthboundManager = manager
        }
        southboundConnecting = task
        do {
            try await task.value
            if southboundConnecting == task {
                southboundConnecting = nil
                southboundRetryAfter = nil
            }
        } catch {
            if southboundConnecting == task {
                southboundConnecting = nil
                southboundRetryAfter = .now.advanced(by: .seconds(5))
            }
            throw error
        }
    }
    #endif

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
    func southboundConnectionString() async throws -> String {
        if let configured = chassisConfig.remote, !configured.isEmpty {
            return configured
        }
        let result = try await runProcess(
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
