import AppTestSupport
import Fluent
import Foundation
import StratoShared
import Testing

@testable import App

@Suite("Steady-state divergence sweep", .serialized)
struct SteadyStateDivergenceTests {
    @Test("The sweep honors grace and exclusions, detects both kinds, and deduplicates episodes")
    func detectsSustainedDivergence() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Divergence Org")
            let project = try await builder.createProject(
                name: "Divergence Project", description: "sweep fixtures",
                organization: organization)

            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let cutoff = now.addingTimeInterval(-AgentMaintenanceLoop.steadyStateDivergenceGrace)

            func vm(
                _ name: String,
                desired: DesiredVMStatus = .running,
                status: VMStatus = .shutdown,
                generation: Int64 = 4,
                observedGeneration: Int64 = 4,
                changedAt: Date,
                deadline: Date? = nil
            ) async throws -> VM {
                let vm = try await builder.createVM(name: name, project: project)
                vm.desiredStatus = desired
                vm.setStatus(status, at: changedAt)
                vm.generation = generation
                vm.observedGeneration = observedGeneration
                vm.convergenceDeadline = deadline
                try await vm.save(on: app.db)
                return vm
            }

            let divergedVM = try await vm("diverged-vm", changedAt: cutoff)
            let recentVM = try await vm(
                "recent-vm", changedAt: cutoff.addingTimeInterval(1))
            _ = try await vm(
                "pending-vm", changedAt: cutoff,
                deadline: now.addingTimeInterval(60))
            _ = try await vm(
                "behind-vm", generation: 4, observedGeneration: 3, changedAt: cutoff)
            _ = try await vm("absent-vm", desired: .absent, changedAt: cutoff)
            _ = try await vm("satisfied-vm", status: .running, changedAt: cutoff)

            let divergedSandbox = try await builder.createSandbox(
                name: "diverged-sandbox", project: project)
            divergedSandbox.desiredStatus = .running
            divergedSandbox.setStatus(.stopped, at: cutoff)
            divergedSandbox.generation = 7
            divergedSandbox.observedGeneration = 7
            try await divergedSandbox.save(on: app.db)

            let first = await app.agentMaintenance.sweepSteadyStateDivergence(now: now)
            #expect(first == .init(vms: 1, sandboxes: 1, newlyDetected: 2))
            #expect(try #require(await VM.find(divergedVM.id, on: app.db)).divergenceDetectedAt == now)
            #expect(
                try #require(await Sandbox.find(divergedSandbox.id, on: app.db))
                    .divergenceDetectedAt == now)

            // The standing gauge counts remain, while the per-episode claims
            // prevent a second replica/pass from producing duplicate warnings.
            let second = await app.agentMaintenance.sweepSteadyStateDivergence(now: now)
            #expect(second == .init(vms: 1, sandboxes: 1, newlyDetected: 0))

            // A recovered status starts a fresh episode and clears the claim.
            divergedVM.setStatus(.running, at: now)
            try await divergedVM.save(on: app.db)
            divergedSandbox.setStatus(.running, at: now)
            try await divergedSandbox.save(on: app.db)
            #expect(try #require(await VM.find(divergedVM.id, on: app.db)).divergenceDetectedAt == nil)
            #expect(
                try #require(await Sandbox.find(divergedSandbox.id, on: app.db))
                    .divergenceDetectedAt == nil)
            let recovered = await app.agentMaintenance.sweepSteadyStateDivergence(now: now)
            #expect(recovered == .init(vms: 0, sandboxes: 0, newlyDetected: 0))

            // The exact 15-minute boundary is inclusive.
            recentVM.statusChangedAt = cutoff
            try await recentVM.save(on: app.db)
            let boundary = await app.agentMaintenance.sweepSteadyStateDivergence(now: now)
            #expect(boundary == .init(vms: 1, sandboxes: 0, newlyDetected: 1))
        }
    }
}
