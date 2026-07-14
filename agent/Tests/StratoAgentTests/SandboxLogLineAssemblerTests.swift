import Foundation
import Testing

@testable import StratoAgentCore

/// Coverage for the log-follow line assembler (issue #423): chunked and
/// interleaved records reassemble into complete lines, invalid UTF-8 decodes
/// lossily, and oversized or end-of-stream partial lines are flushed.
@Suite("Sandbox Log Line Assembler Tests")
struct SandboxLogLineAssemblerTests {

    private typealias Line = SandboxLogLineAssembler.Line

    @Test("One chunk carrying several lines emits them all, in order")
    func multipleLinesPerChunk() {
        var assembler = SandboxLogLineAssembler()
        let lines = assembler.append(stream: "stdout", data: Data("first\nsecond\nthird\n".utf8))
        let expected = [
            Line(stream: "stdout", text: "first"),
            Line(stream: "stdout", text: "second"),
            Line(stream: "stdout", text: "third"),
        ]
        #expect(lines == expected)
        #expect(assembler.flush() == [])
    }

    @Test("A line split across many chunks is emitted once, whole")
    func lineSpanningChunks() {
        var assembler = SandboxLogLineAssembler()
        #expect(assembler.append(stream: "stdout", data: Data("hel".utf8)) == [])
        #expect(assembler.append(stream: "stdout", data: Data("lo wo".utf8)) == [])
        let lines = assembler.append(stream: "stdout", data: Data("rld\n".utf8))
        #expect(lines == [Line(stream: "stdout", text: "hello world")])
    }

    @Test("A chunk can both complete a buffered line and start a new one")
    func chunkCompletesAndStartsLines() {
        var assembler = SandboxLogLineAssembler()
        #expect(assembler.append(stream: "stdout", data: Data("tail of".utf8)) == [])
        let lines = assembler.append(stream: "stdout", data: Data(" one\nstart of two".utf8))
        #expect(lines == [Line(stream: "stdout", text: "tail of one")])
        let final = assembler.append(stream: "stdout", data: Data("\n".utf8))
        #expect(final == [Line(stream: "stdout", text: "start of two")])
    }

    @Test("Interleaved streams keep independent partial-line buffers")
    func interleavedStreamsStayIndependent() {
        var assembler = SandboxLogLineAssembler()
        #expect(assembler.append(stream: "stdout", data: Data("out-".utf8)) == [])
        #expect(assembler.append(stream: "stderr", data: Data("err-".utf8)) == [])

        let stderrLines = assembler.append(stream: "stderr", data: Data("line\n".utf8))
        #expect(stderrLines == [Line(stream: "stderr", text: "err-line")])

        let stdoutLines = assembler.append(stream: "stdout", data: Data("line\n".utf8))
        #expect(stdoutLines == [Line(stream: "stdout", text: "out-line")])
    }

    @Test("Invalid UTF-8 decodes lossily instead of dropping the line")
    func invalidUTF8IsLossy() {
        var assembler = SandboxLogLineAssembler()
        var data = Data("ok ".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(contentsOf: Data(" end\n".utf8))
        let lines = assembler.append(stream: "stdout", data: data)
        #expect(lines.count == 1)
        let text = lines.first?.text
        #expect(text == "ok \u{FFFD}\u{FFFD} end")
    }

    @Test("A partial line beyond the byte cap is force-flushed in cap-sized pieces")
    func oversizedPartialLineIsFlushed() {
        var assembler = SandboxLogLineAssembler(maxLineBytes: 8)
        let lines = assembler.append(stream: "stdout", data: Data("abcdefghijklmnopqr".utf8))
        // 18 bytes, no newline: two 8-byte flushes, 2 bytes stay buffered.
        let expected = [
            Line(stream: "stdout", text: "abcdefgh"),
            Line(stream: "stdout", text: "ijklmnop"),
        ]
        #expect(lines == expected)
        #expect(assembler.flush() == [Line(stream: "stdout", text: "qr")])
    }

    @Test("A partial line exactly at the cap keeps buffering; its newline completes it whole")
    func atCapBoundaryKeepsBuffering() {
        var assembler = SandboxLogLineAssembler(maxLineBytes: 4)
        // Exactly at the cap: not yet *exceeding* it, so nothing is flushed.
        #expect(assembler.append(stream: "stdout", data: Data("abcd".utf8)) == [])
        // The next chunk carries the newline: a complete line wins over the cap
        // check (memory stays bounded by cap + chunk size either way).
        let lines = assembler.append(stream: "stdout", data: Data("e\n".utf8))
        #expect(lines == [Line(stream: "stdout", text: "abcde")])
    }

    @Test("flush emits every stream's partial line (ordered by stream) and resets")
    func flushEmitsPartialsAndResets() {
        var assembler = SandboxLogLineAssembler()
        #expect(assembler.append(stream: "stderr", data: Data("err partial".utf8)) == [])
        #expect(assembler.append(stream: "stdout", data: Data("out partial".utf8)) == [])

        let flushed = assembler.flush()
        let expected = [
            Line(stream: "stderr", text: "err partial"),
            Line(stream: "stdout", text: "out partial"),
        ]
        #expect(flushed == expected)
        // A second flush has nothing left.
        #expect(assembler.flush() == [])
    }

    @Test("Empty chunks and empty lines behave: no-op vs. an empty line")
    func emptyChunksAndLines() {
        var assembler = SandboxLogLineAssembler()
        #expect(assembler.append(stream: "stdout", data: Data()) == [])
        // A bare newline is a (legitimate) empty line.
        let lines = assembler.append(stream: "stdout", data: Data("\n".utf8))
        #expect(lines == [Line(stream: "stdout", text: "")])
        #expect(assembler.flush() == [])
    }
}
