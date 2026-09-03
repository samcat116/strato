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

    struct NetworkConnectTimeout: Error, LocalizedError {
        let seconds: Int64
        var errorDescription: String? {
            "network service connect timed out after \(seconds)s — are the OVN/OVS daemons responsive?"
        }
    }

    /// Attempts to connect the network service, bounded by a timeout so a
    /// hung OVN/OVS database socket cannot stall agent startup indefinitely
    /// (the underlying connect has no deadline of its own). The budget covers
    /// the database connects plus chassis bootstrap and the ovn-controller
    /// connection check (which polls for several seconds on an unhealthy
    /// host). Returns whether the service is connected.
    func connectNetworkService(timeoutSeconds: Int64 = 30) async -> Bool {
        guard let service = networkService else { return false }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await service.connect() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw NetworkConnectTimeout(seconds: timeoutSeconds)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
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

            // Reset any half-open state left by the failed (or timed-out)
            // attempt before dialing again.
            if let service = networkService {
                await service.disconnect()
            }

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
