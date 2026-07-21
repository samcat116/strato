import Foundation

/// Extracts whole JSON objects from a qga byte stream (issue #563).
///
/// qga frames replies as bare JSON objects, not newline-delimited records, and
/// `guest-sync-delimited` prefixes its reply with a `0xFF` marker the client
/// uses to discard any stale buffered bytes. This framer handles both: scan to
/// (and past) a sync marker, then hand back one complete top-level object at a
/// time, brace-counting with string/escape awareness so a `}` inside a JSON
/// string never closes the object early.
///
/// A reference type so it can be threaded through the client's async read loop
/// without `inout` gymnastics across suspension points.
final class QGAObjectFramer {
    private var buffer: [UInt8] = []

    private static let openBrace: UInt8 = 0x7B  // {
    private static let closeBrace: UInt8 = 0x7D  // }
    private static let quote: UInt8 = 0x22  // "
    private static let backslash: UInt8 = 0x5C  // \
    private static let syncMarker: UInt8 = 0xFF

    /// Upper bound on buffered bytes. A guest that streams a never-closing
    /// object would otherwise grow memory unbounded within a probe's budget;
    /// qga replies are small, so 1 MiB is far above any legitimate one.
    private let maxBufferedBytes: Int

    init(maxBufferedBytes: Int = 1 << 20) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// Whether the buffer has grown past its cap without yielding a complete
    /// object — a broken or hostile stream the client should abandon.
    var isOverBudget: Bool { buffer.count > maxBufferedBytes }

    func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// Discards bytes up to and including the first `0xFF` sync marker. Returns
    /// `true` once a marker has been consumed (the buffer is then positioned at
    /// the first byte after it — the start of the resync reply). Returns `false`
    /// when no marker is buffered yet, having discarded everything scanned so it
    /// is not re-scanned on the next call.
    func consumeThroughSyncMarker() -> Bool {
        if let index = buffer.firstIndex(of: Self.syncMarker) {
            buffer.removeFirst(index + 1)
            return true
        }
        // No marker yet: drop what we have (it's pre-marker noise) so a huge
        // pre-sync dump can't accumulate unboundedly.
        buffer.removeAll(keepingCapacity: true)
        return false
    }

    /// Returns the next complete top-level JSON object as raw UTF-8 bytes,
    /// advancing past it, or `nil` if the buffer does not yet hold a whole one.
    /// Leading whitespace, newlines, and stray `0xFF` markers are skipped.
    func nextObject() -> [UInt8]? {
        // Skip anything before the first '{' — whitespace, newlines, stray sync
        // markers, or partial garbage left by a desynchronized guest.
        var start = 0
        while start < buffer.count, buffer[start] != Self.openBrace {
            start += 1
        }
        guard start < buffer.count else {
            // No object start in view; discard the scanned noise.
            buffer.removeAll(keepingCapacity: true)
            return nil
        }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < buffer.count {
            let byte = buffer[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == Self.backslash {
                    escaped = true
                } else if byte == Self.quote {
                    inString = false
                }
            } else if byte == Self.quote {
                inString = true
            } else if byte == Self.openBrace {
                depth += 1
            } else if byte == Self.closeBrace {
                depth -= 1
                if depth == 0 {
                    let object = Array(buffer[start...i])
                    buffer.removeFirst(i + 1)
                    return object
                }
            }
            i += 1
        }

        // Incomplete object: drop only the skipped leading noise, keep the
        // partial object for the next append.
        if start > 0 {
            buffer.removeFirst(start)
        }
        return nil
    }
}
