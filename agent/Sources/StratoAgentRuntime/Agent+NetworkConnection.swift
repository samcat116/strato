import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import StratoShared
import StratoAgentCore
import StratoAgentSPIFFE

#if os(Linux)
// One shared Firecracker client backs both VMs and sandboxes (issue #421).
import SwiftFirecracker
// geteuid(): the jailer needs root, so the start-time jailer resolution
// (issue #425) checks the effective uid.
import Glibc
#endif

/// Owns network-service connection establishment and recovery.
extension Agent {
    // MARK: - Network service connection

    /// The network service owns its attempt, transport deadline, and cleanup.
    func connectNetworkService() async -> Bool {
        guard !shutdownRequested, let service = networkService else { return false }
        do {
            try await service.connect()
            guard !shutdownRequested, !Task.isCancelled else { return false }
            logger.info("Network service connected successfully")
            return true
        } catch {
            logger.warning("Failed to connect to network service: \(error.localizedDescription)")
            return false
        }
    }

    /// Starts the background loop that keeps retrying a failed network
    /// service connection with backoff. Guarded against duplicates.
    func startNetworkReconnectLoop() {
        guard networkConnectTask == nil else { return }
        networkConnectTask = Task { [weak self] in
            await self?.runNetworkReconnectLoop()
        }
    }

    /// Retries the network service connection with exponential backoff. On
    /// success, re-registers with the control plane (registration is an
    /// idempotent upsert) so the recovered networking capability is
    /// advertised immediately instead of after the next reconnect or restart.
    func runNetworkReconnectLoop() async {
        defer { networkConnectTask = nil }

        var delaySeconds = 5.0
        let maxDelaySeconds = 60.0

        while !shutdownRequested, !networkServiceConnected {
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return  // cancelled (agent stopping)
            }
            guard !shutdownRequested else { return }

            if await connectNetworkService() {
                networkServiceConnected = true
                logger.info("Network service connected after retry")
                if assignedAgentID != nil {
                    do {
                        try await registerWithControlPlane()
                        logger.info("Re-registered with control plane to advertise recovered networking capability")
                    } catch {
                        logger.warning(
                            "Could not refresh registration after network recovery; capability updates on next reconnect: \(error)"
                        )
                    }
                }
                return
            }

            delaySeconds = min(delaySeconds * 2, maxDelaySeconds)
        }
    }
}
