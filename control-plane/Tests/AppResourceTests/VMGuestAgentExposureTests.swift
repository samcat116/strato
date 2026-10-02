import AppTestSupport
import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
@testable import App

@Suite("VM guest-agent opt-in exposure")
struct VMGuestAgentExposureTests {
    private func vm() -> VM {
        VM(
            id: UUID(), name: "agent", description: "", image: "linux", projectID: UUID(),
            environment: "", cpu: 1, memory: 1_073_741_824, disk: 1_073_741_824)
    }

    @Test func metadataOnlyInstallsForExplicitOptIn() {
        let vm = vm()
        func metadata() -> InstanceMetadata {
            InstanceMetadata.build(
                vm: vm, vmId: vm.id!, resolvedInterfaces: [], region: nil,
                availabilityZone: nil, instanceSPIFFEID: nil)
        }
        #expect(metadata().guestAgentRelease == nil)
        vm.guestAgentEnabled = true
        vm.userData = "#!/bin/sh\necho tenant"
        #expect(metadata().guestAgentRelease == GuestAgentBootstrap.defaultRelease)
        #expect(metadata().userData == vm.userData)
    }

    @Test func enabledDoesNotImplyReachableAndStoppedDoesNotExposeOldProbe() {
        let vm = vm()
        vm.guestAgentEnabled = true
        vm.status = .running
        vm.qgaAvailable = true
        #expect(VMDetailResponse(from: vm).guestAgentEnabled)
        #expect(VMDetailResponse(from: vm).guestAgentObservation == nil)
        vm.guestAgentObservation = GuestAgentObservation(reachable: true, checkedAt: Date())
        #expect(VMDetailResponse(from: vm).guestAgentObservation?.reachable == true)
        vm.status = .shutdown
        #expect(VMDetailResponse(from: vm).guestAgentObservation == nil)
        vm.status = .running
        vm.guestAgentEnabled = false
        #expect(VMDetailResponse(from: vm).guestAgentObservation == nil)
    }

    @Test func observationMigrationPreservesExistingVMsAndReverts() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema("vms").field("id", .uuid, .identifier(auto: false)).create()
            try await AddGuestAgentObservationToVM().prepare(on: app.db)
            try await AddGuestAgentObservationToVM().revert(on: app.db)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
