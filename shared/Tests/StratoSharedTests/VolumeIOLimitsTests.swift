import Foundation
import Testing
import StratoShared

/// The contract behind `VolumeIOLimits` (STR-19).
///
/// `VolumeIOLimits(nil, nil)` and `nil` are two spellings of one fact, and the
/// two sides of the wire resolve that ambiguity in *opposite* directions: the
/// desired side normalizes to nil, the observed side must not. Get them the
/// wrong way round and nothing fails loudly — a planner re-plans a throttle
/// forever, or an agent's silence reads as a deliberate clear — so this suite
/// is what pins the rule, especially while no agent implements the feature and
/// there is no integration path that would notice.
@Suite("Volume I/O limits wire format")
struct VolumeIOLimitsTests {

    // MARK: - Normalization (the desired side)

    @Test func allNilNormalizesToNil() {
        #expect(VolumeIOLimits.normalized(iopsTotal: nil, bpsTotal: nil) == nil)
    }

    @Test func aSingleCapSurvivesNormalization() throws {
        let limits = try #require(VolumeIOLimits.normalized(iopsTotal: 500, bpsTotal: nil))
        #expect(limits.iopsTotal == 500)
        #expect(limits.bpsTotal == nil)
        #expect(limits.isEmpty == false)

        let bpsOnly = try #require(VolumeIOLimits.normalized(iopsTotal: nil, bpsTotal: 1 << 20))
        #expect(bpsOnly.iopsTotal == nil)
        #expect(bpsOnly.bpsTotal == 1 << 20)
    }

    @Test func anAllNilValueIsEmptyButNotEqualToNil() {
        let empty = VolumeIOLimits()
        #expect(empty.isEmpty)
        // The whole reason `normalized` exists: `Optional` equality cannot see
        // through the wrapper, so an unnormalized producer would emit a value
        // that compares unequal to every consumer's nil.
        #expect(Optional(empty) != VolumeIOLimits?.none)
    }

    // MARK: - Present-but-empty vs absent (the observed side)

    /// The single most important assertion here. An agent that applied no caps
    /// sends `{}`; an agent that does not report caps at all omits the key.
    /// Both decode without error, and they must not decode to the same thing.
    @Test func presentButEmptyIsDistinguishableFromAbsent() throws {
        let empty: VolumeIOLimits? = VolumeIOLimits()
        let encoded = try encodeJSON(empty)
        #expect(String(decoding: encoded, as: UTF8.self) == "{}")

        let decodedEmpty = try decodeJSON(VolumeIOLimits?.self, from: "{}")
        #expect(decodedEmpty != nil)
        #expect(decodedEmpty?.isEmpty == true)

        let decodedAbsent = try decodeJSON(VolumeIOLimits?.self, from: "null")
        #expect(decodedAbsent == nil)
    }

    @Test func roundTripsBothCaps() throws {
        let decoded = try roundTrip(VolumeIOLimits(iopsTotal: 500, bpsTotal: 1 << 20))
        #expect(decoded.iopsTotal == 500)
        #expect(decoded.bpsTotal == 1 << 20)
    }

    // MARK: - Field placement

    /// A v33 payload — no `ioLimits` key anywhere — must still decode, and must
    /// decode as "no caps" rather than failing the whole sync.
    @Test func aPreV34DesiredVolumeStateDecodesWithNoLimits() throws {
        let json = """
            {
              "volumeId": "\(UUID().uuidString)",
              "desiredStatus": "Present",
              "generation": 3,
              "sizeBytes": 10737418240,
              "format": "qcow2"
            }
            """
        let decoded = try decodeJSON(DesiredVolumeState.self, from: json)
        #expect(decoded.ioLimits == nil)
        #expect(decoded.sizeBytes == 10_737_418_240)
    }

    @Test func aPreV34ObservedVolumeStateDecodesWithNoLimits() throws {
        let json = """
            {
              "volumeId": "\(UUID().uuidString)",
              "present": true,
              "observedGeneration": 3
            }
            """
        let decoded = try decodeJSON(ObservedVolumeState.self, from: json)
        #expect(decoded.ioLimits == nil)
    }

    @Test func desiredAndObservedStatesCarryLimitsOnTheWire() throws {
        let desired = DesiredVolumeState(
            volumeId: UUID(),
            desiredStatus: .present,
            generation: 1,
            sizeBytes: 1 << 30,
            format: "qcow2",
            ioLimits: VolumeIOLimits(iopsTotal: 500))
        #expect(try encodedKeys(desired).contains("ioLimits"))
        #expect(try roundTrip(desired).ioLimits?.iopsTotal == 500)

        let observed = ObservedVolumeState(
            volumeId: UUID(),
            present: true,
            observedGeneration: 1,
            ioLimits: VolumeIOLimits(iopsTotal: 500))
        #expect(try encodedKeys(observed).contains("ioLimits"))
        #expect(try roundTrip(observed).ioLimits?.iopsTotal == 500)
    }

    /// An uncapped desired entry omits the key entirely, which is what the
    /// normalization rule buys: one spelling of "uncapped" on the wire.
    @Test func anUncappedDesiredStateOmitsTheKey() throws {
        let desired = DesiredVolumeState(
            volumeId: UUID(),
            desiredStatus: .present,
            generation: 1,
            sizeBytes: 1 << 30,
            format: "qcow2",
            ioLimits: VolumeIOLimits.normalized(iopsTotal: nil, bpsTotal: nil))
        #expect(try encodedKeys(desired).contains("ioLimits") == false)
    }

    @Test func volumeSpecCarriesLimitsAndRequiresManagedIdentity() throws {
        let spec = VolumeSpec(
            volumeId: UUID(),
            deviceName: VolumeDeviceName.disk(1),
            attachment: .file(path: "/var/lib/strato/volumes/v/volume.qcow2", format: .qcow2),
            ioLimits: VolumeIOLimits(bpsTotal: 1 << 20))
        #expect(try roundTrip(spec).ioLimits?.bpsTotal == 1 << 20)

        let json = """
            { "deviceName": "disk1", "readonly": false }
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(VolumeSpec.self, from: json)
        }
    }
}
