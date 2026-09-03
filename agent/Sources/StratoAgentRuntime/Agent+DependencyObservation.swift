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

/// Owns ongoing observation of node-local service dependencies.
extension Agent {
    // MARK: - Node dependency observation (STR-237)

    func startDependencyObservation() async throws {
        let modules: [any NodeDependencyModule]
        if isSimulationMode {
            modules = [
                SimulatedNodeDependencyModule(
                    id: .spire, role: .identity, affectedCapabilities: [.workloadIdentity]),
                SimulatedNodeDependencyModule(
                    id: .libvirt, role: .compute, affectedCapabilities: [.qemuPlacement]),
                SimulatedNodeDependencyModule(
                    id: .ovnOvs, role: .networking,
                    affectedCapabilities: [.overlayNetworking, .sandboxNetworking, .networkResolver]),
            ]
        } else {
            let systemd = SystemdHostAdapter()
            let spireVersionCache = NodeDependencyProbeCache<String?>()
            guard let svidManager else {
                throw AgentError.spiffeConfigurationError(
                    "dependency observation started before the SVID manager")
            }
            var registry: [any NodeDependencyModule] = [
                SPIRENodeDependencyModule(
                    systemd: systemd,
                    source: spiffeConfig?.sourceType == "files" ? .files : .workloadAPI,
                    installMode: installMode,
                    version: {
                        await spireVersionCache.value(maxAge: 300) {
                            await DependencyVersionProbe.version(
                                candidates: [
                                    "/opt/spire/bin/spire-agent",
                                    "/usr/local/bin/spire-agent",
                                    "/usr/bin/spire-agent",
                                ], arguments: ["-version"])
                        }
                    },
                    svid: {
                        do {
                            return .ready(expiresAt: try await svidManager.getSVID().expiresAt)
                        } catch {
                            return .unavailable(
                                "SPIFFE identity source did not provide a usable X.509 SVID: \(error.localizedDescription)"
                            )
                        }
                    })
            ]

            #if os(Linux)
            let libvirtVersionCache = NodeDependencyProbeCache<String?>()
            registry.append(
                LibvirtNodeDependencyModule(
                    systemd: systemd,
                    installedVersion: {
                        await libvirtVersionCache.value(maxAge: 300) {
                            await DependencyVersionProbe.version(
                                candidates: ["/usr/bin/virsh", "/usr/local/bin/virsh"])
                        }
                    },
                    probe: { await LibvirtProbe.probe() }))

            let cephVersionCache = NodeDependencyProbeCache<String?>()
            registry.append(
                CephClientNodeDependencyModule(
                    version: {
                        await cephVersionCache.value(maxAge: 300) {
                            await DependencyVersionProbe.version(
                                candidates: [CephRBDStorageBackend.defaultRBDPath],
                                arguments: ["--version"])
                        }
                    },
                    libvirt: { await LibvirtProbe.probe() },
                    qemuAttachmentsEnabled: hypervisorType == .qemu,
                    functional: {
                        let files = FileManager.default
                        guard files.isExecutableFile(atPath: CephRBDStorageBackend.defaultRBDPath) else {
                            return .unhealthy(
                                "Ceph RBD client is not executable",
                                code: .missingBinary)
                        }
                        return .healthy
                    }))
            #endif

            if effectiveNetworkMode == .ovn {
                let ovsVersionCache = NodeDependencyProbeCache<String?>()
                let ovnVersionCache = NodeDependencyProbeCache<String?>()
                let service = networkService
                registry.append(
                    OVNOVSNodeDependencyModule(
                        systemd: systemd,
                        ovsVersion: {
                            await ovsVersionCache.value(maxAge: 300) {
                                await DependencyVersionProbe.version(
                                    candidates: [
                                        "/usr/sbin/ovs-vswitchd", "/usr/bin/ovs-vswitchd",
                                        "/usr/local/sbin/ovs-vswitchd",
                                    ])
                            }
                        },
                        ovnVersion: {
                            await ovnVersionCache.value(maxAge: 300) {
                                await DependencyVersionProbe.version(
                                    candidates: [
                                        "/usr/sbin/ovn-controller", "/usr/bin/ovn-controller",
                                        "/usr/local/sbin/ovn-controller",
                                    ])
                            }
                        },
                        functional: {
                            guard let service else {
                                return .unhealthy("OVN networking is configured but no network service exists")
                            }
                            return await service.inspectDependencyHealth()
                        }))
            }
            modules = registry
        }

        let manager = try NodeDependencyManager(modules: modules, logger: logger)
        dependencyManager = manager
        // Registration carries this initial authoritative snapshot, avoiding a
        // placement window before the first heartbeat.
        await manager.refresh()
        dependencyObservationTask = Task { [weak self] in
            await self?.runDependencyObservationLoop()
        }
    }

    func runDependencyObservationLoop() async {
        while !Task.isCancelled, !shutdownRequested {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard !shutdownRequested, let dependencyManager else { return }
            // Delivery 1 is observation-only. Even a future module accidentally
            // registered as repair-capable receives no lifecycle authority here.
            await dependencyManager.refresh()
        }
    }
}
