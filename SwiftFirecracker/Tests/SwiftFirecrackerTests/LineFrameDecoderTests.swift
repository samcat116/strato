import NIOCore
import NIOEmbedded
import Testing

@testable import SwiftFirecracker

/// Coverage for ``LineFrameDecoder``, the newline framer sitting under the guest
/// control channel (STR-73).
///
/// This is the point where bytes a tenant guest chose become discrete lines for
/// the protocol parser, so what matters is not only that it splits correctly but
/// that a guest which never sends a newline gets its connection torn down rather
/// than growing the host's buffer forever.
@Suite("Line frame decoder")
struct LineFrameDecoderTests {

    /// An ``EmbeddedChannel`` carrying just the framer, so lines can be read
    /// back with `readInbound` without a socket in the way.
    private func makeChannel(maximumLineLength: Int = 1024) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(LineFrameDecoder(maximumLineLength: maximumLineLength)))
        return channel
    }

    private func write(_ text: String, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try channel.writeInbound(buffer)
    }

    private func drain(_ channel: EmbeddedChannel) throws -> [String] {
        var lines: [String] = []
        while let buffer = try channel.readInbound(as: ByteBuffer.self) {
            lines.append(String(buffer: buffer))
        }
        return lines
    }

    @Test("several lines in one read are emitted separately, without delimiters")
    func splitsMultipleLines() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }

        try write("{\"a\":1}\n{\"b\":2}\n", to: channel)
        #expect(try drain(channel) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test("a line split across reads is reassembled")
    func reassemblesSplitLine() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }

        try write("{\"ty", to: channel)
        #expect(try drain(channel).isEmpty)
        try write("pe\":\"pong\"}", to: channel)
        #expect(try drain(channel).isEmpty)
        try write("\n", to: channel)
        #expect(try drain(channel) == [#"{"type":"pong"}"#])
    }

    @Test("empty lines are preserved as empty frames")
    func emitsEmptyLines() throws {
        let channel = try makeChannel()
        defer { _ = try? channel.finish() }

        try write("\n\nx\n", to: channel)
        #expect(try drain(channel) == ["", "", "x"])
    }

    @Test("an unterminated line past the cap fails the channel instead of accumulating")
    func unterminatedLineIsRefused() throws {
        let channel = try makeChannel(maximumLineLength: 64)
        defer { _ = try? channel.finish() }

        // Feed well past the cap in chunks, the way a guest spraying bytes with
        // no newline would. The framer must give up, not keep buffering.
        var threw = false
        for _ in 0..<32 {
            do {
                try write(String(repeating: "A", count: 16), to: channel)
            } catch is FirecrackerError {
                threw = true
                break
            }
        }
        #expect(threw, "the framer accepted more than 64 bytes without a newline")
        #expect(try drain(channel).isEmpty)
    }

    @Test("a line exactly at the cap is still delivered")
    func lineAtCapDelivered() throws {
        let channel = try makeChannel(maximumLineLength: 64)
        defer { _ = try? channel.finish() }

        let line = String(repeating: "A", count: 64)
        try write(line, to: channel)  // at the cap, no newline yet: keep waiting
        #expect(try drain(channel).isEmpty)
        try write("\n", to: channel)
        #expect(try drain(channel) == [line])
    }

    @Test("arbitrary chunk boundaries never change the framing")
    func framingIsIndependentOfChunking() throws {
        let lines = [#"{"type":"pong"}"#, "", #"{"type":"log","seq":1}"#, "x", String(repeating: "y", count: 300)]
        let stream = lines.map { $0 + "\n" }.joined()
        let bytes = Array(stream.utf8)

        // Deterministic: a failure reproduces from the seed.
        var state: UInt64 = 0x5EED
        func nextRandom() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        for _ in 0..<200 {
            let channel = try makeChannel(maximumLineLength: 1024)
            defer { _ = try? channel.finish() }

            var framed: [String] = []
            var offset = 0
            while offset < bytes.count {
                let size = 1 + Int(nextRandom() % 64)
                let end = min(bytes.count, offset + size)
                var buffer = channel.allocator.buffer(capacity: end - offset)
                buffer.writeBytes(bytes[offset..<end])
                try channel.writeInbound(buffer)
                framed.append(contentsOf: try drain(channel))
                offset = end
            }
            #expect(framed == lines)
        }
    }
}
