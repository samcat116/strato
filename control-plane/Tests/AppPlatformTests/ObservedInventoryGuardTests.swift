import Testing
import Vapor

@testable import App

@Suite("Observed inventory blast-radius guard")
struct ObservedInventoryGuardTests {
    @Test("The first destructive report is held; empty and pending-only hosts can establish a baseline")
    func firstInventory() async throws {
        let policy = ObservedInventoryGuard(
            configuration: try await ControlPlaneConfiguration.load(environmentVariables: [:], for: .testing))
        #expect(
            policy.refusal(counts: [.workloads: .init(placed: 1, destructiveAbsences: 1)], acceptedSections: []) != nil)
        #expect(policy.refusal(counts: [.workloads: .init()], acceptedSections: []) == nil)
        #expect(
            policy.refusal(counts: [.workloads: .init(placed: 10, destructiveAbsences: 0)], acceptedSections: []) == nil
        )
    }

    @Test("Both the absolute floor and percentage must be exceeded; exact boundaries remain allowed")
    func thresholds() async throws {
        let policy = ObservedInventoryGuard(
            configuration: try await ControlPlaneConfiguration.load(environmentVariables: [:], for: .testing))
        #expect(
            policy.refusal(
                counts: [.workloads: .init(placed: 3, destructiveAbsences: 3)], acceptedSections: [.workloads]) == nil)
        #expect(
            policy.refusal(
                counts: [.workloads: .init(placed: 16, destructiveAbsences: 4)], acceptedSections: [.workloads]) == nil)
        #expect(
            policy.refusal(
                counts: [.workloads: .init(placed: 15, destructiveAbsences: 4)], acceptedSections: [.workloads]) != nil)
        #expect(
            policy.refusal(
                counts: [.workloads: .init(placed: 100, destructiveAbsences: 4)], acceptedSections: [.workloads]) == nil
        )
    }

    @Test("Nil storage observations cannot establish their first inventory or dilute loss")
    func independentStorageBaseline() async throws {
        let policy = ObservedInventoryGuard(
            configuration: try await ControlPlaneConfiguration.load(environmentVariables: [:], for: .testing))
        for section in [ObservedInventoryGuard.Section.volumes, .snapshots] {
            #expect(
                policy.refusal(
                    counts: [.workloads: .init(placed: 100), section: .init(placed: 1, destructiveAbsences: 1)],
                    acceptedSections: [.workloads]) != nil)
        }
        #expect(
            policy.refusal(
                counts: [
                    .workloads: .init(placed: 2, destructiveAbsences: 2),
                    .volumes: .init(placed: 2, destructiveAbsences: 2),
                ],
                acceptedSections: [.workloads, .volumes]) != nil)
    }

    @Test("Configured thresholds and deliberate operator override are honored")
    func configuration() async throws {
        let configured = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "OBSERVED_INVENTORY_MINIMUM_RESOURCES": "0", "OBSERVED_INVENTORY_PERCENT_OF_PLACED": "10",
            ], for: .testing)
        let counts: [ObservedInventoryGuard.Section: ObservedInventoryGuard.Counts] = [
            .workloads: .init(placed: 5, destructiveAbsences: 1)
        ]
        #expect(
            ObservedInventoryGuard(configuration: configured).refusal(counts: counts, acceptedSections: [.workloads])
                != nil)
        let override = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "OBSERVED_INVENTORY_ALLOW_BULK_LOSS": "true"
            ], for: .testing)
        #expect(ObservedInventoryGuard(configuration: override).refusal(counts: counts, acceptedSections: []) == nil)
        for variables in [
            ["OBSERVED_INVENTORY_MINIMUM_RESOURCES": "-1"],
            ["OBSERVED_INVENTORY_PERCENT_OF_PLACED": "101"],
            ["OBSERVED_INVENTORY_PERCENT_OF_PLACED": "-1"],
        ] {
            await #expect(throws: ControlPlaneConfigurationError.self) {
                _ = try await ControlPlaneConfiguration.load(environmentVariables: variables, for: .testing)
            }
        }
    }
}
