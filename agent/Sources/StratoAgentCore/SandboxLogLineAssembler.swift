import Foundation

/// Reassembles a sandbox's log follow stream — arbitrary `(stream, bytes)`
/// chunks — into complete UTF-8 lines (issue #423).
///
/// The guest ring buffer stores raw output chunks, so one logical line may
/// arrive split across several records and one record may carry several lines.
/// The assembler buffers a partial line per stream and emits a line whenever a
/// `\n` completes it, decoding lossily (invalid UTF-8 becomes replacement
/// characters) with the newline stripped.
///
/// A partial line is force-flushed in two cases: when its buffer exceeds
/// `maxLineBytes` (a workload emitting an unbounded line must not grow host
/// memory), and on end-of-stream via `flush()`.
public struct SandboxLogLineAssembler: Sendable {
    /// One assembled output line.
    public struct Line: Equatable, Sendable {
        /// "stdout" or "stderr".
        public let stream: String
        /// The line's text, lossily decoded, without the trailing newline.
        public let text: String

        public init(stream: String, text: String) {
            self.stream = stream
            self.text = text
        }
    }

    /// Flush threshold for a partial line, in bytes (8 KiB per spec).
    public static let defaultMaxLineBytes = 8192

    private let maxLineBytes: Int
    /// Partial (not yet newline-terminated) line bytes per stream.
    private var partial: [String: Data] = [:]

    public init(maxLineBytes: Int = SandboxLogLineAssembler.defaultMaxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Feed one chunk of `stream` and return every line it completed, in
    /// order. Oversized partial lines are flushed as lines of `maxLineBytes`
    /// bytes each (a flush boundary may lossily split a multi-byte character).
    public mutating func append(stream: String, data: Data) -> [Line] {
        guard !data.isEmpty else { return [] }
        var buffer = partial[stream] ?? Data()
        buffer.append(data)

        var lines: [Line] = []
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Self.line(stream: stream, bytes: buffer[buffer.startIndex..<newline]))
                buffer = Data(buffer[buffer.index(after: newline)...])
            } else if buffer.count > maxLineBytes {
                lines.append(Self.line(stream: stream, bytes: buffer.prefix(maxLineBytes)))
                buffer = Data(buffer.dropFirst(maxLineBytes))
            } else {
                break
            }
        }

        partial[stream] = buffer.isEmpty ? nil : buffer
        return lines
    }

    /// End-of-stream: emit any buffered partial line per stream (ordered by
    /// stream name so the output is deterministic) and reset the assembler.
    public mutating func flush() -> [Line] {
        let flushed = partial.sorted { $0.key < $1.key }
            .filter { !$0.value.isEmpty }
            .map { Self.line(stream: $0.key, bytes: $0.value) }
        partial = [:]
        return flushed
    }

    private static func line(stream: String, bytes: some Collection<UInt8>) -> Line {
        Line(stream: stream, text: String(decoding: bytes, as: UTF8.self))
    }
}
