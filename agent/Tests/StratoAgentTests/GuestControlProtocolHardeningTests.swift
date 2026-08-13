import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// Hardening coverage for ``GuestControlProtocol/Response/decode(line:)`` — the
/// host's parser for bytes that come out of a tenant guest (STR-73).
///
/// The threat model is the one behind 42baf82 (`Throw instead of trapping on
/// hostile tar entries in OCI layers`): a Swift runtime trap on this path aborts
/// the whole agent process, so it does not degrade one tenant's exec session, it
/// kills every VM on the hypervisor node. The contract these tests pin is
/// therefore total-function-ness — for **any** input, `decode` either returns a
/// response satisfying the protocol's invariants or throws a
/// ``GuestControlError``. Nothing else, ever.
@Suite("Guest Control Protocol Hardening")
struct GuestControlProtocolHardeningTests {

    private typealias Limits = GuestControlProtocol.Limits

    // MARK: - Line length

    @Test("a line past the byte cap is refused, and by the line cap specifically")
    func oversizedLineRefused() {
        // The bulk goes in an *unknown* field, which has no cap of its own and
        // which the decoder otherwise ignores. So the line guard is the only
        // thing that can reject this: assert the case, not just that something
        // threw, or deleting the guard would leave the test green.
        let filler = String(repeating: "a", count: Limits.maxLineBytes)
        let line = #"{"type":"log_eof","nonce":"n","x":"\#(filler)"}"#
        let error = #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: line)
        }
        guard case .responseTooLarge(_, let limit)? = error else {
            Issue.record("expected a line cap rejection, got \(String(describing: error))")
            return
        }
        #expect(limit == Limits.maxLineBytes)
    }

    @Test("a line at the byte cap is still parsed")
    func lineAtCapAccepted() {
        // Same shape one byte shorter: it must decode, proving the cap does not
        // fire early. Unknown fields are ignored, so this is a plain log_eof.
        let base = #"{"type":"log_eof","nonce":"n","x":""}"#
        let filler = String(repeating: "a", count: Limits.maxLineBytes - base.utf8.count)
        let line = #"{"type":"log_eof","nonce":"n","x":"\#(filler)"}"#
        #expect(line.utf8.count == Limits.maxLineBytes)
        #expect((try? GuestControlProtocol.Response.decode(line: line)) == .logEof(nonce: "n"))
    }

    // MARK: - Field length caps

    @Test("an oversized error message is clipped, not thrown away")
    func oversizedMessageTruncated() throws {
        // `message` is purely diagnostic, so the bound is truncation: rejecting
        // would replace the guest's actual complaint with "field too large".
        let message = "boom: " + String(repeating: "x", count: Limits.maxMessageBytes)
        let response = try GuestControlProtocol.Response.decode(
            line: #"{"type":"error","nonce":"n","message":"\#(message)"}"#)
        guard case .error(_, let delivered) = response else {
            Issue.record("expected an error response, got \(response)")
            return
        }
        #expect(delivered.utf8.count <= Limits.maxMessageBytes)
        #expect(delivered.hasPrefix("boom: "), "the head of the diagnostic must survive")
        #expect(delivered.hasSuffix("…[truncated]"), "a clipped message must say so")
    }

    @Test("an error message at the cap is delivered whole, unmarked")
    func messageAtCapUntouched() {
        let atCap = String(repeating: "x", count: Limits.maxMessageBytes)
        let accepted = try? GuestControlProtocol.Response.decode(
            line: #"{"type":"error","nonce":"n","message":"\#(atCap)"}"#)
        #expect(accepted == .error(nonce: "n", message: atCap))
    }

    @Test("oversized identity fields are refused on pong and status")
    func oversizedIdentityRefused() {
        let id = String(repeating: "i", count: Limits.maxIdentifierBytes + 1)
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"pong","sandbox_id":"\#(id)","nonce":"n"}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(
                line: #"{"type":"status","sandbox_id":"s","nonce":"\#(id)","state":"running"}"#)
        }
    }

    @Test("responses without identity fields are rejected")
    func missingIdentityIsRejected() {
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(
                line: #"{"type":"pong","control_protocol_version":4}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"status","state":"running"}"#)
        }
        for line in [
            #"{"type":"exec_started"}"#,
            #"{"type":"output","stream":"stdout","data":"aGk="}"#,
            #"{"type":"exec_exit","exit_code":0}"#,
            #"{"type":"error","message":"boom"}"#,
        ] {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(line: line)
            }
        }
    }

    @Test("multi-byte characters count against a cap as bytes, not as characters")
    func capsCountUTF8Bytes() {
        // 200 emoji: well under the 256-character mark, well over 256 bytes.
        let emoji = String(repeating: "🙂", count: 200)
        #expect(emoji.count < Limits.maxIdentifierBytes)
        #expect(emoji.utf8.count > Limits.maxIdentifierBytes)
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(
                line: #"{"type":"pong","sandbox_id":"\#(emoji)","nonce":"n"}"#)
        }
    }

    // MARK: - Base64 stdio payloads

    @Test("an oversized stdio payload is refused without being decoded")
    func oversizedPayloadRefused() {
        let payload = Data(repeating: 0x41, count: Limits.maxPayloadBytes + 1).base64EncodedString()
        for type in ["output", "log"] {
            let line = #"{"type":"\#(type)","seq":1,"stream":"stdout","data":"\#(payload)"}"#
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(line: line)
            }
        }
    }

    @Test("a payload exactly at the cap is accepted")
    func payloadAtCapAccepted() throws {
        let bytes = Data(repeating: 0x41, count: Limits.maxPayloadBytes)
        let line = #"{"type":"output","nonce":"n","stream":"stdout","data":"\#(bytes.base64EncodedString())"}"#
        let response = try GuestControlProtocol.Response.decode(line: line)
        #expect(response == .output(nonce: "n", stream: "stdout", data: bytes))
    }

    @Test("the encoded-length cap admits every payload the byte cap does")
    func encodedCapMatchesByteCap() {
        // A mismatch here would reject legitimate maximum-size chunks.
        #expect(
            Limits.maxEncodedPayloadBytes
                >= Data(repeating: 0, count: Limits.maxPayloadBytes)
                .base64EncodedString().utf8.count)
    }

    // MARK: - Stream labels

    @Test("an unknown stream label is refused")
    func unknownStreamRefused() {
        // The host buffers a partial line per stream name, so accepting
        // arbitrary labels would be an unbounded-memory primitive.
        for label in ["", "stdin", "STDOUT", "stdout\u{0}", String(repeating: "s", count: 4096)] {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"log","nonce":"n","seq":1,"stream":"\#(label)","data":"aGk="}"#)
            }
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"output","nonce":"n","stream":"\#(label)","data":"aGk="}"#)
            }
        }
    }

    // MARK: - Numeric ranges

    @Test("a log seq near UInt64.max is refused")
    func oversizedSeqRefused() {
        // Regression: the follow loop resumes at `lastSeq + 1`, so a guest that
        // claimed UInt64.max used to be able to trap the agent process on the
        // next reconnect.
        for seq in [UInt64.max, UInt64.max - 1, Limits.maxLogSeq + 1] {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"log","nonce":"n","seq":\#(seq),"stream":"stdout","data":"aGk="}"#)
            }
        }
        let accepted = try? GuestControlProtocol.Response.decode(
            line: #"{"type":"log","nonce":"n","seq":\#(Limits.maxLogSeq),"stream":"stdout","data":"aGk="}"#)
        #expect(
            accepted
                == .log(
                    nonce: "n", seq: Limits.maxLogSeq, stream: "stdout", data: Data("hi".utf8)))
    }

    @Test("an exit code outside the guest's i32 range is refused")
    func outOfRangeExitCodeRefused() {
        let outside = [Int(Int32.max) + 1, Int(Int32.min) - 1, Int.max, Int.min]
        for value in outside {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"exec_exit","nonce":"n","exit_code":\#(value)}"#)
            }
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"status","sandbox_id":"s","nonce":"n","state":"exited","exit_code":\#(value)}"#)
            }
        }
        let edges = try? GuestControlProtocol.Response.decode(
            line: #"{"type":"exec_exit","nonce":"n","exit_code":\#(Int32.min)}"#)
        #expect(edges == .execExit(nonce: "n", exitCode: Int(Int32.min)))
    }

    @Test("an out-of-range control protocol version is refused, not compared against")
    func outOfRangeProtocolVersionRefused() {
        for value in [-1, Int(UInt32.max) + 1] {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(
                    line: #"{"type":"pong","sandbox_id":"s","nonce":"n","control_protocol_version":\#(value)}"#)
            }
        }
    }

    @Test("numbers too large for their field's Swift type are a rejection, not a crash")
    func unrepresentableNumbersRefused() {
        let lines = [
            #"{"type":"exec_exit","nonce":"n","exit_code":99999999999999999999999999}"#,
            #"{"type":"log","nonce":"n","seq":-1,"stream":"stdout","data":"aGk="}"#,
            #"{"type":"log","nonce":"n","seq":1e400,"stream":"stdout","data":"aGk="}"#,
            #"{"type":"exec_exit","nonce":"n","exit_code":1.5}"#,
            #"{"type":"exec_exit","nonce":"n","exit_code":NaN}"#,
        ]
        for line in lines {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(line: line)
            }
        }
    }

    // MARK: - Error payloads

    @Test("a malformed-line error carries a bounded excerpt of the guest's bytes")
    func malformedErrorExcerptIsBounded() {
        let line = #"{"type":"\#(String(repeating: "z", count: 100_000))"}"#
        let error = #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: line)
        }
        guard case .malformedResponse(let excerpt)? = error else {
            Issue.record("expected a malformed-response rejection, got \(String(describing: error))")
            return
        }
        #expect(excerpt.utf8.count <= Limits.excerptBytes)
    }

    @Test("excerpt truncation cannot be inflated by long grapheme clusters")
    func excerptTruncatesByBytes() {
        // One Character, ~4 KiB of combining marks: a character-wise prefix
        // would let this straight through into the log.
        let bomb = "e" + String(repeating: "\u{0301}", count: 2000)
        let error = GuestControlError.malformed(bomb)
        guard case .malformedResponse(let excerpt) = error else {
            Issue.record("unexpected case")
            return
        }
        #expect(excerpt.utf8.count <= Limits.excerptBytes)
    }

    // MARK: - Structural hostility

    @Test("deeply nested JSON is rejected without exhausting the stack")
    func deepNestingRejected() {
        for depth in [64, 1_000, 20_000] {
            let line =
                #"{"type":"log","nonce":"n","seq":1,"a":"# + String(repeating: "[", count: depth)
                + String(repeating: "]", count: depth) + "}"
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(line: line)
            }
        }
    }

    @Test("non-object, empty, and non-JSON lines are rejected")
    func nonObjectLinesRejected() {
        let lines = [
            "", "   ", "\n", "null", "[]", "[1,2,3]", "\"exec_started\"", "42",
            "{", "}", "{\"type\"", #"{"type":}"#, #"{"type":"exec_started","nonce":"n""#,
            "\u{0}\u{0}\u{0}", "\u{FFFD}", #"{"type":123}"#, #"{"type":null}"#, "{}",
        ]
        for line in lines {
            #expect(throws: GuestControlError.self) {
                try GuestControlProtocol.Response.decode(line: line)
            }
        }
    }

    // MARK: - Fuzzing

    /// Corpus-mutation fuzzing over the whole response surface.
    ///
    /// Seeded and deterministic, so it runs in the ordinary suite and a failure
    /// reproduces from the seed printed with it. Set `STRATO_FUZZ_ITERATIONS` to
    /// crank it up for a longer local soak.
    ///
    /// The oracle is the parser's contract, not a second implementation: every
    /// input either throws a ``GuestControlError`` or yields a response whose
    /// every field is inside the documented limits. A Swift trap fails this test
    /// by aborting the test process, which is the point.
    @Test("mutated guest lines either decode within the limits or throw")
    func fuzzMutatedCorpus() {
        let iterations = Self.fuzzIterations
        for seed in fuzzSeeds {
            var random = SplitMix64(seed: seed)
            for iteration in 0..<iterations {
                let candidate = Self.mutatedLine(&random)
                do {
                    let response = try GuestControlProtocol.Response.decode(line: candidate)
                    if let violation = Self.limitViolation(in: response) {
                        Issue.record(
                            """
                            decode returned an out-of-limit response (seed \(seed), iteration \(iteration)): \
                            \(violation)
                            """)
                        return
                    }
                } catch is GuestControlError {
                    continue  // the documented rejection path
                } catch {
                    Issue.record(
                        """
                        decode threw a non-GuestControlError (seed \(seed), iteration \(iteration)): \
                        \(type(of: error)) \(error)
                        """)
                    return
                }
            }
        }
    }

    @Test("uniformly random bytes either decode within the limits or throw")
    func fuzzRandomBytes() {
        for seed in fuzzSeeds {
            var random = SplitMix64(seed: seed &* 31)
            for iteration in 0..<Self.fuzzIterations {
                let length = random.int(upTo: 256)
                let bytes = (0..<length).map { _ in random.byte() }
                // Exactly what the transport hands the decoder: invalid UTF-8 is
                // already repaired into replacement characters upstream.
                let candidate = String(decoding: bytes, as: UTF8.self)
                do {
                    let response = try GuestControlProtocol.Response.decode(line: candidate)
                    if let violation = Self.limitViolation(in: response) {
                        Issue.record(
                            "decode returned an out-of-limit response (seed \(seed), \(iteration)): \(violation)")
                        return
                    }
                } catch is GuestControlError {
                    continue
                } catch {
                    Issue.record("decode threw a non-GuestControlError (seed \(seed), \(iteration)): \(error)")
                    return
                }
            }
        }
    }

    private var fuzzSeeds: [UInt64] { [0x5EED, 0xC0FFEE, 0xDEAD_BEEF, 1, UInt64.max] }

    /// Inputs per seed. The default keeps the suite quick — tests build
    /// unoptimized, and the generators, not the parser, are what cost — while
    /// `STRATO_FUZZ_ITERATIONS` turns the same test into a long local soak.
    private static var fuzzIterations: Int {
        ProcessInfo.processInfo.environment["STRATO_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 4_000
    }

    // MARK: - Fuzz oracle

    /// The invariant every successfully decoded response must satisfy, stated
    /// independently of the parser that produced it. Returns a description of
    /// the first violation, or nil.
    private static func limitViolation(in response: GuestControlProtocol.Response) -> String? {
        func checkIdentity(_ value: String, _ field: String) -> String? {
            value.utf8.count <= Limits.maxIdentifierBytes ? nil : "\(field) is \(value.utf8.count) bytes"
        }
        func checkStdio(_ stream: String, _ data: Data) -> String? {
            if !GuestControlProtocol.allowedStreams.contains(stream) { return "stream label '\(stream)'" }
            if data.count > Limits.maxPayloadBytes { return "payload is \(data.count) bytes" }
            return nil
        }
        func checkExitCode(_ code: Int?) -> String? {
            guard let code, code < Int(Int32.min) || code > Int(Int32.max) else { return nil }
            return "exit code \(code)"
        }

        switch response {
        case .pong(let id, let nonce, let version):
            if let violation = checkIdentity(id, "sandbox_id") ?? checkIdentity(nonce, "nonce") { return violation }
            if id.isEmpty || nonce.isEmpty { return "empty identity" }
            if version != SandboxGuestControlProtocol.currentVersion { return "protocol version \(version)" }
            return nil
        case .status(let id, let nonce, _, let exitCode):
            return checkIdentity(id, "sandbox_id") ?? checkIdentity(nonce, "nonce") ?? checkExitCode(exitCode)
        case .error(let nonce, let message):
            return checkIdentity(nonce, "nonce")
                ?? (message.utf8.count <= Limits.maxMessageBytes ? nil : "message is \(message.utf8.count) bytes")
        case .output(let nonce, let stream, let data):
            return checkIdentity(nonce, "nonce") ?? checkStdio(stream, data)
        case .execExit(let nonce, let exitCode):
            return checkIdentity(nonce, "nonce") ?? checkExitCode(exitCode)
        case .log(let nonce, let seq, let stream, let data):
            if let violation = checkIdentity(nonce, "nonce") { return violation }
            if seq > Limits.maxLogSeq { return "seq \(seq)" }
            return checkStdio(stream, data)
        case .execStarted(let nonce), .logEof(let nonce), .clockSynced(let nonce),
            .launched(let nonce), .reidentified(let nonce):
            return checkIdentity(nonce, "nonce")
        }
    }

    // MARK: - Fuzz input generation

    /// Well-formed lines the mutators start from, one per response type, so a
    /// mutation lands in a code path that would otherwise be hard to reach by
    /// chance.
    private static let corpus: [String] = [
        #"{"type":"pong","sandbox_id":"sb-1","nonce":"n-1","control_protocol_version":4}"#,
        #"{"type":"status","sandbox_id":"sb-1","nonce":"n-1","state":"exited","exit_code":137}"#,
        #"{"type":"status","sandbox_id":"sb-1","nonce":"n-1","state":"held"}"#,
        #"{"type":"error","nonce":"n","message":"spawn failed"}"#,
        #"{"type":"exec_started","nonce":"n"}"#,
        #"{"type":"output","nonce":"n","stream":"stderr","data":"b29wcwo="}"#,
        #"{"type":"exec_exit","nonce":"n","exit_code":0}"#,
        #"{"type":"log","nonce":"n","seq":18,"stream":"stdout","data":"bGluZQo="}"#,
        #"{"type":"log_eof","nonce":"n"}"#,
        #"{"type":"clock_synced","nonce":"n"}"#,
        #"{"type":"launched","nonce":"n"}"#,
        #"{"type":"reidentified","nonce":"n"}"#,
    ]

    /// Interesting scalars to splice into a numeric or string position — the
    /// values a hand-written test would reach for, offered to the mutator so it
    /// finds combinations a human would not.
    private static let hostileScalars: [String] = [
        "18446744073709551615", "-1", "0", "9223372036854775808", "-9223372036854775809",
        "1e400", "NaN", "Infinity", "1.5", "null", "true", "[]", "{}", #""""#,
        #""stdin""#, #""%%%""#, #""\ud800""#, "\u{0}",
    ]

    private static func mutatedLine(_ random: inout SplitMix64) -> String {
        var bytes = Array(corpus[random.int(upTo: corpus.count)].utf8)

        // One to four stacked mutations: a single edit mostly produces invalid
        // JSON, which never reaches the field validators.
        for _ in 0...random.int(upTo: 4) {
            guard !bytes.isEmpty else { break }
            switch random.int(upTo: 8) {
            case 0:  // flip a byte
                bytes[random.int(upTo: bytes.count)] ^= UInt8(truncatingIfNeeded: random.next())
            case 1:  // delete a span
                let start = random.int(upTo: bytes.count)
                let end = min(bytes.count, start + 1 + random.int(upTo: 8))
                bytes.removeSubrange(start..<end)
            case 2:  // insert random bytes
                let at = random.int(upTo: bytes.count + 1)
                bytes.insert(contentsOf: (0...random.int(upTo: 8)).map { _ in random.byte() }, at: at)
            case 3:  // truncate
                bytes = Array(bytes.prefix(random.int(upTo: bytes.count + 1)))
            case 4:  // splice in a hostile scalar
                let at = random.int(upTo: bytes.count + 1)
                let scalar = hostileScalars[random.int(upTo: hostileScalars.count)]
                bytes.insert(contentsOf: Array(scalar.utf8), at: at)
            case 5:  // blow one region up to a size that should trip a cap
                let at = random.int(upTo: bytes.count + 1)
                let filler = [UInt8](repeating: 0x41, count: 1 << (8 + random.int(upTo: 8)))
                bytes.insert(contentsOf: filler, at: at)
            case 6:  // duplicate a span (repeated keys, unbalanced braces)
                let start = random.int(upTo: bytes.count)
                let end = min(bytes.count, start + 1 + random.int(upTo: 32))
                // Copied out first: inserting a slice of `bytes` into `bytes`
                // is an exclusivity violation.
                let span = Array(bytes[start..<end])
                bytes.insert(contentsOf: span, at: random.int(upTo: bytes.count + 1))
            default:  // nest a structure inside the object
                let depth = 1 + random.int(upTo: 64)
                let nest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
                bytes.insert(contentsOf: Array(#","x":\#(nest)"#.utf8), at: max(0, bytes.count - 1))
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A tiny seeded PRNG, so a fuzz failure reproduces exactly from the seed the
/// test reports. `SystemRandomNumberGenerator` would not.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<bound` (0 when `bound` is not positive).
    mutating func int(upTo bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}
