import Foundation
import Testing
import StratoShared

/// The wire contract behind `ObservedVolumeState.sizeBytes` (STR-199, v38).
///
/// The field ships without a capability gate, so absence is the whole
/// compatibility story and it has to mean one thing only: *this agent said
/// nothing*. A pre-v38 agent omits the key on every report, and the control
/// plane reads that as "leave the recorded size alone" rather than "this volume
/// has no size" — a misreading that would blank a real measurement on every
/// heartbeat, and would do it silently.
@Suite("Observed volume size wire format")
struct VolumeObservedSizeWireTests {

    /// A v37 payload — no `sizeBytes` key at all — must still decode, and must
    /// decode as "no answer" rather than failing the whole report.
    @Test func aPreV38ObservedVolumeStateDecodesWithNoSize() throws {
        let json = """
            {
              "volumeId": "\(UUID().uuidString)",
              "present": true,
              "storagePath": "/var/lib/strato/volumes/v/volume.qcow2",
              "format": "qcow2",
              "observedGeneration": 3
            }
            """
        let decoded = try decodeJSON(ObservedVolumeState.self, from: json)
        #expect(decoded.sizeBytes == nil)
        #expect(decoded.present)
        #expect(decoded.observedGeneration == 3)
    }

    /// An explicit null is the same answer as an absent key. Nothing emits one
    /// today — the encoder omits nil — but `openapi.yaml` declares the field
    /// nullable, so a generated client may, and it must not fail the decode.
    @Test func anExplicitNullSizeDecodesAsNoAnswer() throws {
        let json = """
            {
              "volumeId": "\(UUID().uuidString)",
              "present": true,
              "observedGeneration": 1,
              "sizeBytes": null
            }
            """
        #expect(try decodeJSON(ObservedVolumeState.self, from: json).sizeBytes == nil)
    }

    /// A volume the agent could not probe is reported the same way a pre-v38
    /// agent reports every volume: the key is absent, not zero. Zero is a real
    /// size, and one that would read as "this image has nothing in it".
    @Test func anUnreportedSizeIsOmittedRatherThanZeroed() throws {
        let observed = ObservedVolumeState(
            volumeId: UUID(), present: true, sizeBytes: nil, observedGeneration: 1)
        #expect(try encodedKeys(observed).contains("sizeBytes") == false)
        #expect(try roundTrip(observed).sizeBytes == nil)
    }

    @Test func areportedSizeSurvivesTheRoundTrip() throws {
        let observed = ObservedVolumeState(
            volumeId: UUID(), present: true, storagePath: "/v/volume.qcow2",
            sizeBytes: 1 << 30, observedGeneration: 4)
        #expect(try encodedKeys(observed).contains("sizeBytes"))
        #expect(try roundTrip(observed).sizeBytes == 1 << 30)
    }
}
