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
/// Scanning is **resumable**: the parse cursor and brace/string state persist
/// across calls, so a reply arriving in N socket chunks is scanned once end to
/// end rather than re-scanned from the top after every chunk. That was
/// immaterial while every qga reply was a few hundred bytes; a
/// `guest-exec-status` carrying a command's base64 output is megabytes, and
/// re-scanning per chunk would make reassembly quadratic in the reply size.
///
/// A reference type so it can be threaded through the client's async read loop
/// without `inout` gymnastics across suspension points.
final class QGAObjectFramer {
    private var buffer: [UInt8] = []

    // Resumable scan state. `scanIndex` is the next byte to examine;
    // `objectStart` is where the object under construction began, or nil while
    // still looking for one. The rest is the string/escape machine, which has
    // to survive a chunk boundary landing mid-string just as much as the cursor
    // does.
    private var scanIndex = 0
    private var objectStart: Int?
    private var depth = 0
    private var inString = false
    private var escaped = false

    private static let openBrace: UInt8 = 0x7B  // {
    private static let closeBrace: UInt8 = 0x7D  // }
    private static let quote: UInt8 = 0x22  // "
    private static let backslash: UInt8 = 0x5C  // \
    private static let syncMarker: UInt8 = 0xFF

    /// Upper bound on buffered bytes for an ordinary qga reply. A guest that
    /// streams a never-closing object would otherwise grow memory unbounded
    /// within a probe's budget; qga's status and query replies are small, so
    /// 1 MiB is far above any legitimate one. A `guest-exec-status` carrying a
    /// command's captured output is the exception, and sizes its own framer.
    static let defaultMaxBufferedBytes = 1 << 20

    /// Upper bound on buffered bytes for this framer.
    let maxBufferedBytes: Int

    init(maxBufferedBytes: Int = QGAObjectFramer.defaultMaxBufferedBytes) {
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
        defer { resetScan() }
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
    ///
    /// Every byte is examined once across however many calls it takes for the
    /// object to arrive: a `nil` return leaves the cursor and brace/string state
    /// parked where the data ran out, and the next call resumes from there.
    func nextObject() -> [UInt8]? {
        // Skip anything before the object's opening '{' — whitespace, newlines,
        // stray sync markers, or partial garbage left by a desynchronized
        // guest. Only done while no object is under construction.
        if objectStart == nil {
            while scanIndex < buffer.count, buffer[scanIndex] != Self.openBrace {
                scanIndex += 1
            }
            guard scanIndex < buffer.count else {
                // No object start in view; discard the scanned noise.
                buffer.removeAll(keepingCapacity: true)
                resetScan()
                return nil
            }
            objectStart = scanIndex
        }

        while scanIndex < buffer.count {
            let byte = buffer[scanIndex]
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
                    let start = objectStart ?? 0
                    let object = Array(buffer[start...scanIndex])
                    buffer.removeFirst(scanIndex + 1)
                    resetScan()
                    return object
                }
            }
            scanIndex += 1
        }

        // Incomplete object: drop only the skipped leading noise, keeping the
        // partial object and rebasing the cursor onto the shortened buffer.
        if let start = objectStart, start > 0 {
            buffer.removeFirst(start)
            scanIndex -= start
            objectStart = 0
        }
        return nil
    }

    /// Returns the scan to "looking for the start of an object", which is the
    /// correct state after consuming an object or discarding the buffer.
    private func resetScan() {
        scanIndex = 0
        objectStart = nil
        depth = 0
        inString = false
        escaped = false
    }
}
