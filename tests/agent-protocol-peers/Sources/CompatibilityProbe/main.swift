import BaselinePeer
import Foundation
import NextPeer
import SwiftProtobuf

enum ProbeFailure: Error { case assertion(String) }
func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw ProbeFailure.assertion(label) }
}

typealias Old = BaselinePeer.Strato_Agent_Compat_V1_PeerMessage
typealias New = NextPeer.Strato_Agent_Compat_V1_PeerMessage

// Distinct generated modules, compiled from frozen and additive schemas.
var old = Old()
old.protocolMajor = 1
old.capabilities = ["exec.v1"]
old.inventory = .init()  // Authoritatively empty, distinct from no opinion.
old.output = Data([0, 0xff, 0xc3, 0x28])
let next = try New(serializedBytes: old.serializedData())
try check(next.protocolMajor == 1 && next.hasProtocolMajor, "old to new major")
try check(next.hasInventory && next.inventory.workloadIds.isEmpty, "present empty inventory")
try check(next.output == old.output, "arbitrary stream bytes")
try check(!next.hasFeatureAObservation && !next.hasFeatureBObservation, "absent future fields")

var future = next
future.capabilities += ["feature-a.v1", "feature-b.v1"]
future.featureAObservation = "ready"
future.featureBObservation = UInt64.max
let baseline = try Old(serializedBytes: future.serializedData())
try check(baseline.capabilities == future.capabilities, "unknown advertised capabilities")
try check(!baseline.unknownFields.data.isEmpty, "unknown fields retained")
let relay = try New(serializedBytes: baseline.serializedData())
try check(relay.featureAObservation == "ready", "old peer relay retains feature A")
try check(relay.featureBObservation == UInt64.max, "old peer relay retains feature B without precision loss")

old.clearInventory()
old.clearProtocolMajor()
let absent = try New(serializedBytes: old.serializedData())
try check(!absent.hasInventory, "absence does not become authoritative empty")
try check(!absent.hasProtocolMajor, "missing major is detectable")
print("PASS: independent peer schemas, additive fields, binary relay, presence, and stream bytes")
