import Testing

@testable import StratoShared

@Suite("QEMU memory reservation")
struct QEMUMemoryReservationTests {
    private let mib: Int64 = 1024 * 1024
    private let gib: Int64 = 1024 * 1024 * 1024

    @Test("sub-block arm64 headroom is not reserved")
    func unrealizedArm64Headroom() {
        #expect(
            QEMUMemoryReservation.reservedBytes(
                memoryBytes: gib,
                maxMemoryBytes: gib + 256 * mib,
                architecture: .arm64) == gib)
    }

    @Test("realizable headroom is aligned to the architecture block")
    func alignedHeadroom() {
        #expect(
            QEMUMemoryReservation.reservedBytes(
                memoryBytes: gib,
                maxMemoryBytes: 2 * gib,
                architecture: .arm64) == 2 * gib)
        #expect(
            QEMUMemoryReservation.reservedBytes(
                memoryBytes: gib,
                maxMemoryBytes: gib + 3 * mib,
                architecture: .x86_64) == gib + 2 * mib)
    }

    @Test("near-limit arithmetic does not overflow")
    func saturation() {
        #expect(
            QEMUMemoryReservation.reservedBytes(
                memoryBytes: Int64.max - 1,
                maxMemoryBytes: Int64.max,
                architecture: .x86_64) == Int64.max - 1)
    }
}
