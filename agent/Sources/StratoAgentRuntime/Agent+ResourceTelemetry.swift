import Foundation
import StratoAgentCore
import StratoShared

/// Owns the independent pressure/contention sampling loop (STR-266).
extension Agent {
    static let resourceTelemetrySamplingInterval: Duration = .seconds(15)

    func startResourceTelemetryObservation() {
        resourceTelemetryTask?.cancel()
        resourceTelemetryTask = Task { [weak self] in
            await self?.runResourceTelemetryObservationLoop()
        }
    }

    func runResourceTelemetryObservationLoop() async {
        while !Task.isCancelled, !shutdownRequested {
            let targets = resourceTelemetryProbeTargets()
            // Procfs/sysfs reads are synchronous. Keep them off the agent
            // actor so neither heartbeats nor desired-state reconciliation
            // wait behind a slow filesystem read.
            let snapshot = await Task.detached(priority: .utility) {
                ResourceTelemetryProbe.live.sample(targets: targets)
            }.value
            guard !Task.isCancelled, !shutdownRequested else { return }
            hostResourceTelemetry = snapshot.host
            workloadResourceTelemetry = snapshot.workloads

            do {
                try await Task.sleep(for: Self.resourceTelemetrySamplingInterval)
            } catch {
                return
            }
        }
    }

    /// A bounded target list derived only from durable workload identity and
    /// backend configuration. UUID workload ids are safe path components; no
    /// tenant-controlled workload name is used for path discovery or metrics.
    func resourceTelemetryProbeTargets() -> [WorkloadTelemetryProbeTarget] {
        var targets: [WorkloadTelemetryProbeTarget] = []
        var seen = Set<String>()

        func appendVM(_ id: String, entry: VMManifestEntry) {
            guard seen.insert(id).inserted else { return }
            switch entry.hypervisorType {
            case .qemu:
                targets.append(
                    WorkloadTelemetryProbeTarget(
                        workloadID: id,
                        kind: .vm,
                        pidFilePath: "/run/libvirt/qemu/\(id).pid"))
            case .firecracker:
                // Ordinary Firecracker VMs are unjailed and share the agent's
                // cgroup. Reporting that host cgroup as per-VM contention
                // would falsely attribute every sibling process, so absence is
                // explicit until this backend gains a workload boundary.
                targets.append(WorkloadTelemetryProbeTarget(workloadID: id, kind: .vm))
            }
        }
        for (id, entry) in managedVMs { appendVM(id, entry: entry) }
        for (id, entry) in orphanedVMs { appendVM(id, entry: entry) }

        let firecrackerCgroupParent = URL(fileURLWithPath: firecrackerBinaryPath).lastPathComponent
        func appendSandbox(_ id: String, entry: VMManifestEntry) {
            guard seen.insert(id).inserted else { return }
            let cgroupPath =
                entry.jailerUsed == false
                ? nil : "/sys/fs/cgroup/\(firecrackerCgroupParent)/\(id)"
            targets.append(
                WorkloadTelemetryProbeTarget(
                    workloadID: id, kind: .sandbox,
                    directCgroupPath: cgroupPath))
        }
        for (id, entry) in managedSandboxes { appendSandbox(id, entry: entry) }
        for (id, entry) in orphanedSandboxes { appendSandbox(id, entry: entry) }

        return targets
    }
}
