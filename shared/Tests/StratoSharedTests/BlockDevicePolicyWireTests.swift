import Foundation
import StratoShared
import Testing

@Suite("QEMU block-device policy wire format")
struct BlockDevicePolicyWireTests {
    @Test("older desired and manifest shapes remain conservative")
    func legacyDefaults() throws {
        let volumeID = UUID()
        let desired = try decodeJSON(
            DesiredVolumeState.self,
            from: """
                {
                  "volumeId": "\(volumeID)",
                  "desiredStatus": "Present",
                  "generation": 1,
                  "sizeBytes": 1073741824,
                  "format": "qcow2"
                }
                """)
        #expect(desired.blockMode == .conservative)

        let spec = try decodeJSON(
            VolumeSpec.self,
            from: """
                {
                  "volumeId": "\(volumeID)",
                  "deviceName": "disk0",
                  "readonly": false
                }
                """)
        #expect(spec.blockMode == .conservative)
        #expect(spec.appliedBlockPolicy == nil)
    }

    @Test("requested and applied policy round-trip independently")
    func policyRoundTrip() throws {
        let policy = AppliedBlockDevicePolicy(
            active: true,
            requestedMode: .direct,
            cacheMode: BlockDeviceCacheMode.none,
            ioMode: .ioUring,
            discard: true,
            nonRotational: true,
            queueCount: 8)
        let desired = DesiredVolumeState(
            volumeId: UUID(), desiredStatus: .present, generation: 1,
            sizeBytes: 1 << 30, format: "qcow2", blockMode: .direct)
        #expect(try roundTrip(desired).blockMode == .direct)

        let observed = ObservedVolumeState(
            volumeId: desired.volumeId, present: true, observedGeneration: 1,
            blockPolicy: policy)
        #expect(try roundTrip(observed).blockPolicy == policy)
    }

    @Test("detached is explicit rather than agent silence")
    func inactivePolicy() throws {
        let policy = AppliedBlockDevicePolicy.inactive(requestedMode: .cachedShared)
        #expect(policy.active == false)
        #expect(try roundTrip(policy) == policy)
    }
}
