import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    func resourceEnforcementWillConverge(_ item: ReconcileWorkItem) async {
        guard [.vm, .sandbox].contains(item.kind), let id = UUID(uuidString: item.id) else { return }
        resourceEnforcementProducer.begin(.init(kind: item.kind, id: id), generation: item.generation)
    }

    func resourceEnforcementDidConverge(_ item: ReconcileWorkItem) async {
        guard let application = resourceEnforcementApplication(item) else { return }
        resourceEnforcementProducer.succeeded(application)
    }

    private func resourceEnforcementApplication(_ item: ReconcileWorkItem) -> ResourceEnforcementProducer.Application? {
        guard let id = UUID(uuidString: item.id) else { return nil }
        let resourceClass: WorkloadResourceClassSnapshot?
        let reservation: WorkloadAdmittedReservation?
        let guestBytes: Int64
        let cpuCount: Int
        let backend: WorkloadResourceClassBackend
        if let target = item.desired, let entry = managedVMs[item.id], entry.hypervisorType == .qemu,
            entry.spec.resourceClass == target.spec.resourceClass,
            entry.spec.admittedReservation == target.spec.admittedReservation,
            entry.spec.memoryBytes == target.spec.memoryBytes, entry.spec.cpus == target.spec.cpus
        {
            resourceClass = entry.spec.resourceClass
            reservation = entry.spec.admittedReservation
            guestBytes = entry.spec.memoryBytes
            cpuCount = entry.spec.cpus
            backend = .qemuVM
        } else if let target = item.desiredSandbox, let entry = managedSandboxes[item.id],
            let spec = entry.sandboxSpec, entry.jailerUsed == true,
            spec.resourceClass == target.spec.resourceClass,
            spec.admittedReservation == target.spec.admittedReservation,
            spec.memoryBytes == target.spec.memoryBytes, spec.cpus == target.spec.cpus
        {
            resourceClass = spec.resourceClass
            reservation = spec.admittedReservation
            guestBytes = spec.memoryBytes
            cpuCount = spec.cpus
            backend = .jailedFirecrackerSandbox
        } else {
            return nil
        }
        guard let resourceClass, resourceClass.policy.kind == .burstable, let reservation else { return nil }
        let expectedOverhead =
            backend == .qemuVM
            ? configuration.qemuMemoryOverheadBytes : WorkloadMemoryReservation.firecrackerOverheadBytes
        guard reservation.backendOverheadBytes == expectedOverhead else { return nil }
        return .init(
            key: .init(kind: item.kind, id: id), generation: item.generation,
            resourceClass: resourceClass, backend: backend, reservation: reservation, guestBytes: guestBytes,
            cpuCount: cpuCount)
    }

    /// No awaits after the final fence and resource projection. This snapshot
    /// accompanies that exact report.resources; independent pressure caches
    /// never authorize acknowledgement.
    func captureResourceEnforcement(observedVMs: [ObservedVMState], observedSandboxes: [ObservedSandboxState]) async
        -> (resources: AgentResources, enforcement: ResourceEnforcementSnapshot?)
    {
        let capture = resourceEnforcementProducer.capture()
        let identityBefore = resourceAccountingIdentity()
        let ledgerBefore = capacityAdmissionLedger.revision
        let before = await rawHostCapacitySnapshot()
        var evidence: [ResourceEnforcementProducer.Key: WorkloadResourceLimitsEvidence] = [:]
        for application in capture.applications.values {
            let id = application.key.id.uuidString
            let observedGeneration: Int64?
            if application.key.kind == .vm {
                let records = observedVMs.filter { $0.vmId == application.key.id }
                observedGeneration =
                    records.count == 1
                        && ResourceEnforcementProducer.canAcknowledge(records[0], application: application)
                    ? records[0].observedGeneration : nil
            } else {
                let records = observedSandboxes.filter { $0.sandboxId == application.key.id }
                observedGeneration =
                    records.count == 1
                        && ResourceEnforcementProducer.canAcknowledge(records[0], application: application)
                    ? records[0].observedGeneration : nil
            }
            guard observedGeneration == application.generation,
                let limits = try? BurstableResourceLimits.plan(
                    resourceClass: application.resourceClass,
                    guestGrantBytes: application.guestBytes,
                    backendOverheadBytes: application.reservation.backendOverheadBytes)
            else { continue }
            if application.backend == .qemuVM, let service = hypervisorServices[.qemu] {
                evidence[application.key] = await service.resourceEnforcementEvidence(
                    vmId: id, application: application, desired: limits)
            } else if application.backend == .jailedFirecrackerSandbox, let runtime = sandboxRuntime {
                evidence[application.key] = await runtime.resourceEnforcementEvidence(
                    sandboxId: id, application: application, desired: limits)
            }
        }
        let after = capture.applications.isEmpty ? before : await rawHostCapacitySnapshot()
        let identities =
            Array(managedVMs.keys) + Array(orphanedVMs.keys) + Array(managedSandboxes.keys)
            + Array(orphanedSandboxes.keys) + Array(quarantinedWorkloads.keys)
        let stable =
            identityBefore != nil && identityBefore == resourceAccountingIdentity()
            && identities.count == Set(identities.compactMap(UUID.init(uuidString:))).count
        let snapshot = resourceEnforcementProducer.finish(
            capture, before: before, after: after,
            ledgerRevisionBefore: ledgerBefore, ledgerRevisionAfter: capacityAdmissionLedger.revision,
            inventoryStable: stable, evidence: evidence, sampledAt: Date(),
            pageSize: BurstableCgroupEnforcement.hostPageSizeBytes)
        if let snapshot { return (agentResources(from: after), snapshot) }
        // A legacy nil would let stale accepted capacity remain authoritative
        // after restart or a failed fence. Report explicit unknown instead.
        let unknown = HostCapacitySnapshot(
            total: after.total, reserved: after.reserved,
            inventoryKnown: false, diskInventoryKnown: false, hostReservedMemoryBytes: after.hostReservedMemoryBytes,
            qemuOverheadBytes: after.qemuOverheadBytes, workloadReservations: after.workloadReservations)
        return (agentResources(from: unknown), resourceEnforcementProducer.incompleteSnapshot(sampledAt: Date()))
    }

    private func resourceAccountingIdentity() -> Data? {
        guard quarantinedWorkloads.isEmpty, manifestReadFailure == nil, !manifestPersistFailed else { return nil }
        do {
            let encoder = WireProtocol.makeEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var result = Data()
            func append<T: Encodable>(_ value: T) throws {
                let bytes = try encoder.encode(value)
                result.append(Data("\(bytes.count):".utf8))
                result.append(bytes)
            }
            for entries in [managedVMs, orphanedVMs, managedSandboxes, orphanedSandboxes] {
                try append(entries)
            }
            try append(volumeCommittedSizes)
            try append(Dictionary(uniqueKeysWithValues: snapshotRecords.map { ($0.key.uuidString, $0.value) }))
            return result
        } catch { return nil }
    }
}
