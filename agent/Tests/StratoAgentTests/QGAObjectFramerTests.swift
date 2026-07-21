import Foundation
import Testing

@testable import StratoAgentCore

/// Framing coverage for the qga byte-stream parser (issue #563): whole objects
/// are handed back one at a time, split arrivals reassemble, braces inside JSON
/// strings never close an object early, and the `guest-sync-delimited` `0xFF`
/// marker is consumed correctly.
@Suite("QGA Object Framer")
struct QGAObjectFramerTests {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("A single complete object is extracted")
    func singleObject() {
        let framer = QGAObjectFramer()
        framer.append(bytes(#"{"return": 3}"#))
        let object = framer.nextObject()
        #expect(object.map { String(decoding: $0, as: UTF8.self) } == #"{"return": 3}"#)
        #expect(framer.nextObject() == nil)
    }

    @Test("An object split across appends reassembles")
    func splitObject() {
        let framer = QGAObjectFramer()
        framer.append(bytes(#"{"host-"#))
        #expect(framer.nextObject() == nil)
        framer.append(bytes(#"name": "web01"}"#))
        let object = framer.nextObject()
        #expect(object.map { String(decoding: $0, as: UTF8.self) } == #"{"host-name": "web01"}"#)
    }

    @Test("Two objects arriving together are returned one at a time")
    func backToBackObjects() {
        let framer = QGAObjectFramer()
        framer.append(bytes(#"{"return": 1}{"return": 2}"#))
        #expect(framer.nextObject().map { String(decoding: $0, as: UTF8.self) } == #"{"return": 1}"#)
        #expect(framer.nextObject().map { String(decoding: $0, as: UTF8.self) } == #"{"return": 2}"#)
        #expect(framer.nextObject() == nil)
    }

    @Test("Braces inside a JSON string do not close the object early")
    func bracesInsideString() {
        let framer = QGAObjectFramer()
        // A hostname value containing braces and an escaped quote.
        let raw = #"{"return": {"host-name": "a}{\"b}"}}"#
        framer.append(bytes(raw))
        let object = framer.nextObject()
        #expect(object.map { String(decoding: $0, as: UTF8.self) } == raw)
    }

    @Test("Leading whitespace and newlines are skipped")
    func leadingNoise() {
        let framer = QGAObjectFramer()
        framer.append(bytes("\n\n  {\"return\": {}}"))
        let object = framer.nextObject()
        #expect(object.map { String(decoding: $0, as: UTF8.self) } == #"{"return": {}}"#)
    }

    @Test("consumeThroughSyncMarker discards bytes up to and including 0xFF")
    func syncMarker() {
        let framer = QGAObjectFramer()
        // Stale garbage, the marker, then the real reply.
        framer.append(bytes("leftover garbage"))
        framer.append([0xFF])
        framer.append(bytes(#"{"return": 42}"#))
        #expect(framer.consumeThroughSyncMarker())
        let object = framer.nextObject()
        #expect(object.map { String(decoding: $0, as: UTF8.self) } == #"{"return": 42}"#)
    }

    @Test("consumeThroughSyncMarker returns false when no marker is buffered")
    func syncMarkerAbsent() {
        let framer = QGAObjectFramer()
        framer.append(bytes("no marker yet"))
        #expect(!framer.consumeThroughSyncMarker())
    }

    @Test("A never-closing object trips the buffer budget instead of growing unbounded")
    func overBudget() {
        let framer = QGAObjectFramer(maxBufferedBytes: 16)
        framer.append(bytes(#"{"a":""#))  // open object, no close
        #expect(!framer.isOverBudget)
        framer.append(Array(repeating: UInt8(ascii: "x"), count: 32))
        #expect(framer.isOverBudget)
        // Still no complete object — the client abandons on the budget signal.
        #expect(framer.nextObject() == nil)
    }
}
