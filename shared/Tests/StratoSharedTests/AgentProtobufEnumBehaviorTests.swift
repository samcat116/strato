import Foundation
import Testing

@testable import StratoShared

struct AgentProtobufEnumBehaviorTests {
    @Test func durableEnumNamesRemainStrings() throws {
        #expect(String(decoding: try JSONEncoder().encode(ArtifactKind.diskImage), as: UTF8.self) == "\"disk-image\"")
        #expect(String(decoding: try JSONEncoder().encode(CPUArchitecture.x86_64), as: UTF8.self) == "\"x86_64\"")
        #expect(
            String(decoding: try JSONEncoder().encode(HypervisorType.appleVirtualization), as: UTF8.self)
                == "\"apple_virtualization\"")
        #expect(
            String(decoding: try JSONEncoder().encode(WorkloadKind.volumeSnapshot), as: UTF8.self)
                == "\"volume_snapshot\"")
        #expect(try JSONDecoder().decode(CPUArchitecture.self, from: Data("\"x86_64\"".utf8)) == .x86_64)
        #expect(DiskFormat(volumePath: "/volume/disk.raw") == .raw)
    }

    @Test func unknownEnumValuesCannotBecomeDurablePolicy() {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(ArtifactKind.UNRECOGNIZED(999))
        }
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(CephMessengerMode.unspecified)
        }
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try WorkloadResourceClassPolicy(kind: .UNRECOGNIZED(999))
        }
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try WorkloadResourceClassPolicy(kind: .guaranteed, hardLimitPolicy: .unspecified)
        }
    }

    @Test func unknownPlatformDoesNotClaimRealizationSupport() {
        let support = HypervisorSupport(type: .UNRECOGNIZED(999), available: true, accelerated: true)
        #expect(!support.supportsSnapshots)
        #expect(!support.supportsMemorySize(1 << 30))
        #expect(!WorkloadKind.UNRECOGNIZED(999).isSnapshotArtifact)
        #expect(CPUArchitecture.UNRECOGNIZED(999).displayName == "Unknown")
        #expect(!IPFamily.UNRECOGNIZED(999).matches("192.0.2.1"))
        #expect(!DesiredVMStatus.UNRECOGNIZED(999).isSatisfied(by: .running))
        #expect(!DesiredSandboxStatus.UNRECOGNIZED(999).isSatisfied(by: .exited))
        #expect(SnapshotArtifactKind(WorkloadKind.UNRECOGNIZED(999)) == nil)
        #expect(
            QEMUMemoryReservation.reservedBytes(
                memoryBytes: 1 << 30, maxMemoryBytes: 2 << 30, architecture: .UNRECOGNIZED(999)) == .max)
    }
}
