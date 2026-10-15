import Foundation
import Testing
@testable import StratoShared

@Suite("Apple Virtualization capability contract")
struct AppleVirtualizationSupportTests {
    @Test func backendIdentityAndUnsupportedCheckpointsRoundTrip() throws {
        let support = HypervisorSupport(type: .appleVirtualization, available: true, accelerated: true)
        let encoded = try WireProtocol.makeEncoder().encode(support)
        let decoded = try WireProtocol.makeDecoder().decode(HypervisorSupport.self, from: encoded)
        #expect(decoded.type == .appleVirtualization)
        #expect(!decoded.supportsSnapshots)
        #expect(decoded.supportsGuestExec != true)
        #expect(String(decoding: encoded, as: UTF8.self).contains("apple_virtualization"))
    }

    @Test func memoryAccountingChargesNativeBackendOverheadWithoutHotplugHeadroom() {
        let reservation = WorkloadMemoryReservation.vm(
            memoryBytes: 1 << 30, maxMemoryBytes: 4 << 30,
            hypervisorType: .appleVirtualization, architecture: .arm64)
        #expect(reservation.guestBytes == 1 << 30)
        #expect(reservation.backendOverheadBytes == WorkloadMemoryReservation.appleVirtualizationOverheadBytes)
        #expect(reservation.effectiveBytes == (1 << 30) + (512 << 20))
    }
}
