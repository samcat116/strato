import Foundation
import Logging
import MetricsTestKit
import StratoShared
import Testing

@testable import App

@Suite("Agent dependency health gates")
struct AgentDependencyHealthTests {
    @Test("Duplicate dependency IDs retain only the freshest observation")
    func duplicateDependencyIDs() throws {
        let older = observation(
            .libvirt, capability: .qemuPlacement, state: .unhealthy,
            checkedAt: Date(timeIntervalSince1970: 100))
        let networking = observation(
            .ovnOvs, capability: .overlayNetworking, state: .healthy,
            checkedAt: Date(timeIntervalSince1970: 150))
        let newer = observation(
            .libvirt, capability: .qemuPlacement, state: .healthy,
            checkedAt: Date(timeIntervalSince1970: 200))

        let normalized = AgentService.normalizedDependencyObservations([older, networking, newer])

        #expect(normalized.map(\.id) == [.libvirt, .ovnOvs])
        #expect(try #require(normalized.first).checkedAt == newer.checkedAt)
        #expect(try #require(normalized.first).functionalState == .healthy)
    }

    @Test("Fresh health gates only the capability it affects")
    func featureScopedGating() {
        let now = Date()
        let agent = makeAgent(observations: [
            observation(.libvirt, capability: .qemuPlacement, state: .unhealthy, checkedAt: now),
            observation(.ovnOvs, capability: .overlayNetworking, state: .healthy, checkedAt: now),
        ])

        #expect(!agent.supportedHypervisors.contains(.qemu))
        #expect(agent.supportedHypervisors.contains(.firecracker))
        #expect(agent.supportsInterVMNetworking)
    }

    @Test("Stale observations refuse new placement without changing agent liveness")
    func staleObservation() {
        let now = Date()
        let staleReceipt = now.addingTimeInterval(-61)
        let agent = makeAgent(
            observations: [
                observation(
                    .libvirt, capability: .qemuPlacement, state: .healthy,
                    checkedAt: now.addingTimeInterval(3_600)),
                observation(
                    .ovnOvs, capability: .overlayNetworking, state: .healthy,
                    checkedAt: now.addingTimeInterval(3_600)),
            ], receivedAt: staleReceipt)

        #expect(agent.status == .online)
        #expect(!agent.dependencyAllows(.qemuPlacement, at: now))
        #expect(!agent.dependencyAllows(.overlayNetworking, at: now))
    }

    @Test("Agent clock skew does not change the freshness window")
    func agentClockSkew() {
        let receivedAt = Date(timeIntervalSince1970: 20_000)
        let agent = makeAgent(
            observations: [
                observation(
                    .libvirt, capability: .qemuPlacement, state: .healthy,
                    checkedAt: receivedAt.addingTimeInterval(-3_600)),
                observation(
                    .ovnOvs, capability: .overlayNetworking, state: .healthy,
                    checkedAt: receivedAt.addingTimeInterval(3_600)),
            ], receivedAt: receivedAt)

        let fresh = receivedAt.addingTimeInterval(59)
        #expect(agent.dependencyAllows(.qemuPlacement, at: fresh))
        #expect(agent.dependencyAllows(.overlayNetworking, at: fresh))

        let stale = receivedAt.addingTimeInterval(61)
        #expect(!agent.dependencyAllows(.qemuPlacement, at: stale))
        #expect(!agent.dependencyAllows(.overlayNetworking, at: stale))
    }

    @Test("A first degraded sample remains eligible for hysteresis")
    func degradedHysteresis() {
        let agent = makeAgent(observations: [
            observation(.libvirt, capability: .qemuPlacement, state: .degraded, checkedAt: Date())
        ])
        #expect(agent.supportedHypervisors.contains(.qemu))
    }

    @Test("Repeated healthy dependency observations keep placement available")
    func repeatedHealthyObservationsKeepPlacementAvailable() throws {
        var logger = Logger(label: "test.dependency-health-placement")
        logger.logLevel = .critical
        let scheduler = SchedulerService(logger: logger)
        let requirements = VMPlacementRequirements(
            cpu: 2, memory: 2_048, disk: 20_000,
            hypervisorType: .qemu,
            requiresInterVMNetworking: true)

        for iteration in 0..<150 {
            let now = Date()
            let agent = makeAgent(
                observations: [
                    observation(
                        .libvirt, capability: .qemuPlacement,
                        state: .healthy, checkedAt: now),
                    observation(
                        .ovnOvs, capability: .overlayNetworking,
                        state: .healthy, checkedAt: now),
                ],
                receivedAt: now)
            let candidate = SchedulableAgent(
                id: "node-1", name: agent.name,
                totalCPU: agent.totalCPU, availableCPU: agent.availableCPU,
                totalMemory: agent.totalMemory, availableMemory: agent.availableMemory,
                totalDisk: agent.totalDisk, availableDisk: agent.availableDisk,
                status: agent.status, runningVMCount: 0,
                supportedHypervisors: agent.supportedHypervisors,
                supportsInterVMNetworking: agent.supportsInterVMNetworking)

            try #require(
                candidate.supportedHypervisors.contains(.qemu),
                "QEMU placement became unavailable after observation \(iteration + 1)")
            try #require(
                candidate.supportsInterVMNetworking,
                "OVN placement became unavailable after observation \(iteration + 1)")
            #expect(
                try scheduler.selectAgent(
                    requirements: requirements, from: [candidate], vmName: "stress-vm")
                    == "node-1")
        }
    }

    @Test("Re-registration clears availability only for removed dependencies")
    func removedDependencyMetrics() throws {
        let now = Date()
        let libvirt = observation(
            .libvirt, capability: .qemuPlacement, state: .healthy, checkedAt: now)
        let networking = observation(
            .ovnOvs, capability: .overlayNetworking, state: .healthy, checkedAt: now)
        let metrics = TestMetrics()

        Telemetry.recordDependency(
            agentName: "node-1", observation: libvirt, receivedAt: now, factory: metrics)
        Telemetry.recordDependency(
            agentName: "node-1", observation: networking, receivedAt: now, factory: metrics)
        let libvirtAvailability = try metrics.expectGauge(
            "strato_agent_dependency_available",
            [("agent", "node-1"), ("dependency", NodeDependencyID.libvirt.rawValue)])
        let networkingAvailability = try metrics.expectGauge(
            "strato_agent_dependency_available",
            [("agent", "node-1"), ("dependency", NodeDependencyID.ovnOvs.rawValue)])

        Telemetry.recordRemovedDependenciesUnavailable(
            agentName: "node-1",
            previousObservations: [libvirt, networking],
            currentObservations: [libvirt],
            factory: metrics)

        #expect(libvirtAvailability.lastValue == 1)
        #expect(networkingAvailability.lastValue == 0)
    }

    private func makeAgent(
        observations: [NodeDependencyObservation],
        receivedAt: Date = Date()
    ) -> Agent {
        Agent(
            name: "node-1", hostname: "node-1", version: "test", status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000, availableMemory: 16_000,
                totalDisk: 100_000, availableDisk: 100_000),
            hypervisors: [
                HypervisorSupport(
                    type: .qemu, available: true, accelerated: true,
                    capabilities: .capabilities(for: .qemu)),
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    capabilities: .capabilities(for: .firecracker)),
            ],
            networkCapability: .overlay,
            sandboxCapable: true,
            sandboxNetworkingCapable: true,
            resolverCapable: true,
            dependencyObservations: observations,
            dependencyObservationsReceivedAt: receivedAt)
    }

    private func observation(
        _ id: NodeDependencyID,
        capability: NodeCapability,
        state: NodeDependencyFunctionalState,
        checkedAt: Date
    ) -> NodeDependencyObservation {
        NodeDependencyObservation(
            id: id,
            role: id == .libvirt ? .compute : .networking,
            desiredState: .required,
            ownership: .observeOnly,
            supervisorState: .active,
            compatibility: .compatible,
            functionalState: state,
            checkedAt: checkedAt,
            lastHealthyAt: state == .unhealthy ? nil : checkedAt,
            reason: state == .unhealthy
                ? .init(code: .functionalProbeFailed, message: "test failure") : nil,
            consecutiveFailures: state == .unhealthy ? 2 : 0,
            affectedCapabilities: [capability])
    }
}
