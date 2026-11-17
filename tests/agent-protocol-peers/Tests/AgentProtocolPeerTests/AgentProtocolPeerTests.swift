import BaselinePeer
import Foundation
import NextPeer
import SwiftProtobuf
import Testing

typealias Old = BaselinePeer.Strato_Agent_Compat_V1_PeerMessage
typealias New = NextPeer.Strato_Agent_Compat_V1_PeerMessage

/// Two independently generated modules, compiled from a frozen and an additive
/// schema, exchanging bytes. This proves the SwiftProtobuf behaviours the workload
/// contract relies on (presence, unknown-field relay, raw bytes). Evolution of the
/// real `workload.proto` is checked by `buf breaking` and the shared package tests.
@Suite("Independent baseline and next protocol peers")
struct AgentProtocolPeerTests {
    static func baselineMessage() -> Old {
        var old = Old()
        old.protocolMajor = 1
        old.capabilities = ["exec.v1"]
        old.inventory = .init()  // Authoritatively empty, distinct from no opinion.
        old.output = Data([0, 0xff, 0xc3, 0x28])
        return old
    }

    @Test("a newer peer reads a baseline message without inventing future fields")
    func baselineToNext() throws {
        let old = Self.baselineMessage()
        let next = try New(serializedBytes: old.serializedData())
        #expect(next.hasProtocolMajor)
        #expect(next.protocolMajor == 1)
        #expect(next.hasInventory)
        #expect(next.inventory.workloadIds.isEmpty)
        #expect(next.output == old.output)
        #expect(!next.hasFeatureAObservation)
        #expect(!next.hasFeatureBObservation)
    }

    @Test("a baseline peer relays future fields and capabilities it does not understand")
    func baselineRelaysFutureFields() throws {
        var future = try New(serializedBytes: Self.baselineMessage().serializedData())
        future.capabilities += ["feature-a.v1", "feature-b.v1"]
        future.featureAObservation = "ready"
        future.featureBObservation = UInt64.max
        let baseline = try Old(serializedBytes: future.serializedData())
        #expect(baseline.capabilities == future.capabilities)
        #expect(!baseline.unknownFields.data.isEmpty)
        let relay = try New(serializedBytes: baseline.serializedData())
        #expect(relay.featureAObservation == "ready")
        #expect(relay.featureBObservation == UInt64.max)
    }

    @Test("absence stays distinguishable from an authoritative empty value")
    func absenceIsNotEmpty() throws {
        var old = Self.baselineMessage()
        old.clearInventory()
        old.clearProtocolMajor()
        let absent = try New(serializedBytes: old.serializedData())
        #expect(!absent.hasInventory)
        #expect(!absent.hasProtocolMajor)
    }
}
