import Foundation

/// Framing for the channel between the agent and one of its metadata listeners
/// (STR-56).
///
/// The listener runs as a child process inside its network's namespace, and the
/// agent pushes each network's servable set down that child's stdin. A pipe is a
/// byte stream, so the frames have to delimit themselves: four bytes of
/// big-endian length, then that many bytes of JSON.
///
/// The direction is deliberately one-way. The child answers guests entirely from
/// what it was last pushed, with no request-time call back to the parent, which
/// is the same fail-static posture `MetadataStore` documents: a wedged or
/// restarting agent must not turn into a hung metadata service, because a guest
/// that cannot read its metadata may fail to boot.
public enum MetadataControlProtocol {
    /// The largest frame either side will produce or accept.
    ///
    /// Generous, because a snapshot carries `userData` inline per instance
    /// (~64 KiB each at the cap), and a host can run a lot of instances on one
    /// network. Bounded all the same: the length prefix is the one field a
    /// desynchronized stream will get wrong, and an unbounded reader turns that
    /// into an allocation the size of whatever four bytes happened to say.
    public static let maxFrameBytes = 32 * 1024 * 1024

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case frameTooLarge(bytes: Int)

        public var description: String {
            switch self {
            case .frameTooLarge(let bytes):
                return "metadata control frame of \(bytes) bytes exceeds the \(maxFrameBytes)-byte limit"
            }
        }
    }

    /// Encodes one value as a length-prefixed frame.
    public static func encode(_ value: some Encodable) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxFrameBytes else { throw Error.frameTooLarge(bytes: payload.count) }
        var frame = Data(capacity: payload.count + 4)
        for shift in stride(from: 24, through: 0, by: -8) {
            frame.append(UInt8(truncatingIfNeeded: payload.count >> shift))
        }
        frame.append(payload)
        return frame
    }
}

/// Reassembles frames from a stream that arrives in arbitrary chunks.
public struct MetadataFrameReader: Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int

    public init(maxFrameBytes: Int = MetadataControlProtocol.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Appends `data` and returns every frame that is now complete.
    ///
    /// Throws on a length prefix beyond the limit rather than waiting for bytes
    /// that will never come: a desynchronized stream would otherwise buffer
    /// forever, which looks exactly like a quiet parent.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            var length = 0
            for index in 0..<4 { length = (length << 8) | Int(buffer[buffer.startIndex + index]) }
            guard length <= maxFrameBytes else { throw MetadataControlProtocol.Error.frameTooLarge(bytes: length) }
            guard buffer.count >= length + 4 else { break }
            let start = buffer.startIndex + 4
            frames.append(Data(buffer[start..<(start + length)]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }
}
