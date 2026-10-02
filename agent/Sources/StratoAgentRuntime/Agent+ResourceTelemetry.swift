import Foundation
import Logging
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
            var limitsEvidence = snapshot.resourceLimits
            for target in targets {
                guard let desired = target.resourceLimits else { continue }
                if target.kind == .sandbox, let runtime = sandboxRuntime {
                    limitsEvidence[target.workloadID] = await runtime.resourceLimitsEvidence(
                        sandboxId: target.workloadID, desired: desired)
                } else if let entry = managedVMs[target.workloadID] ?? orphanedVMs[target.workloadID],
                    let service = hypervisorServices[entry.hypervisorType]
                {
                    limitsEvidence[target.workloadID] = await service.resourceLimitsEvidence(
                        vmId: target.workloadID, desired: desired)
                }
            }
            guard !Task.isCancelled, !shutdownRequested else { return }
            let verifiedTargets = targets.compactMap { target -> WorkloadTelemetryProbeTarget? in
                guard let evidence = limitsEvidence[target.workloadID], evidence.ownershipVerified.value == true,
                    let path = evidence.ownedCgroupPath
                else { return nil }
                return WorkloadTelemetryProbeTarget(
                    workloadID: target.workloadID, kind: target.kind, directCgroupPath: path)
            }
            let verifiedMetrics = await Task.detached(priority: .utility) {
                var results: [String: WorkloadResourceTelemetry] = [:]
                for target in verifiedTargets {
                    results[target.workloadID] = ResourceTelemetryProbe.live.sampleWorkload(target, at: Date())
                }
                return results
            }.value
            guard !Task.isCancelled, !shutdownRequested else { return }
            workloadResourceTelemetry.merge(verifiedMetrics) { _, verified in verified }
            for (id, evidence) in limitsEvidence {
                // Diagnostic reporting until the evidence wire schema is
                // coordinated. Unknown acknowledgement never enables placement.
                logger.debug(
                    "Workload resource limits sampled",
                    metadata: Self.resourceLimitsMetadata(id: id, evidence: evidence))
            }

            do {
                try await Task.sleep(for: Self.resourceTelemetrySamplingInterval)
            } catch {
                return
            }
        }
    }

    static func resourceLimitsMetadata(id: String, evidence: WorkloadResourceLimitsEvidence) -> Logger.Metadata {
        func integer(_ value: Int64?) -> Logger.Metadata.Value { .string(value.map { String($0) } ?? "unknown") }
        func flag(_ value: Bool?) -> Logger.Metadata.Value { .string(value.map { String($0) } ?? "unknown") }
        var metadata: Logger.Metadata = ["strato.workload.id": .string(id)]
        metadata["desired.memory.high"] = integer(evidence.desired.memoryHighBytes)
        metadata["desired.memory.max"] = integer(evidence.desired.memoryMaxBytes)
        metadata["desired.cpu.weight"] = integer(Int64(evidence.desired.cpuWeight))
        metadata["target.memory.high"] = integer(evidence.alignedTarget?.memoryHighBytes)
        metadata["target.memory.max"] = integer(evidence.alignedTarget?.memoryMaxBytes)
        metadata["applied.memory.high"] = integer(evidence.appliedMemoryHighBytes.value)
        metadata["applied.memory.max"] = integer(evidence.appliedMemoryMaxBytes.value)
        metadata["applied.cpu.weight"] = integer(evidence.appliedCPUWeight.value)
        metadata["applied.memory.high.unlimited"] = flag(evidence.memoryHighUnlimited.value)
        metadata["applied.memory.max.unlimited"] = flag(evidence.memoryMaxUnlimited.value)
        metadata["applied.cpu.quota.unlimited"] = flag(evidence.cpuQuotaUnlimited.value)
        metadata["ownership.verified"] = flag(evidence.ownershipVerified.value)
        metadata["ownership.path"] = .string(evidence.ownedCgroupPath ?? "unknown")
        metadata["enforcement.acknowledged"] = flag(evidence.enforcementAcknowledged.value)
        return metadata
    }

    /// A bounded target list derived only from durable workload identity and
    /// backend  UUID workload ids are safe path components; no
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
                        pidFilePath: "/run/libvirt/qemu/\(id).pid",
                        resourceLimits: try? BurstableResourceLimits.plan(
                            resourceClass: entry.spec.resourceClass, guestGrantBytes: entry.spec.memoryBytes,
                            backendOverheadBytes: configuration.qemuMemoryOverheadBytes)))
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

        let firecrackerCgroupParent = URL(fileURLWithPath: configuration.firecrackerBinaryPath).lastPathComponent
        func appendSandbox(_ id: String, entry: VMManifestEntry) {
            guard seen.insert(id).inserted else { return }
            let cgroupPath =
                entry.jailerUsed == false
                ? nil : "/sys/fs/cgroup/\(firecrackerCgroupParent)/\(id)"
            targets.append(
                WorkloadTelemetryProbeTarget(
                    workloadID: id, kind: .sandbox,
                    directCgroupPath: cgroupPath,
                    resourceLimits: try? BurstableResourceLimits.plan(
                        resourceClass: entry.sandboxSpec?.resourceClass, guestGrantBytes: entry.spec.memoryBytes,
                        backendOverheadBytes: WorkloadMemoryReservation.firecrackerOverheadBytes)))
        }
        for (id, entry) in managedSandboxes { appendSandbox(id, entry: entry) }
        for (id, entry) in orphanedSandboxes { appendSandbox(id, entry: entry) }

        return targets
    }
}
