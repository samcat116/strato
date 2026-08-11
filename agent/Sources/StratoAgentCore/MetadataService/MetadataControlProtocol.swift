import Foundation
import StratoShared

/// Parent-to-listener frames. Snapshots remain level-triggered state; identity
/// responses are correlated replies to the listener's narrowly scoped mint
/// requests on stdout.
public enum MetadataParentMessage: Codable, Sendable, Equatable {
    case snapshot(MetadataSnapshot)
    case identityResponse(MetadataIdentityResponse)
}

public struct MetadataIdentityRequest: Codable, Sendable, Equatable {
    public let requestId: UUID
    public let vmId: UUID
    public let audience: String
    public let ttlSeconds: Int

    public init(requestId: UUID, vmId: UUID, audience: String, ttlSeconds: Int) {
        self.requestId = requestId
        self.vmId = vmId
        self.audience = audience
        self.ttlSeconds = ttlSeconds
    }
}

public struct MetadataIdentityResponse: Codable, Sendable, Equatable {
    public let requestId: UUID
    public let svid: GuestJWTSVIDResponse?

    public init(requestId: UUID, svid: GuestJWTSVIDResponse?) {
        self.requestId = requestId
        self.svid = svid
    }
}

/// Framing for the channel between the agent and one of its metadata listeners
/// (STR-56).
///
/// The listener runs as a child process inside its network's namespace, and the
/// agent pushes each network's servable set down that child's stdin. A pipe is a
/// byte stream, so the frames have to delimit themselves: four bytes of
/// big-endian length, then that many bytes of JSON.
///
/// Metadata documents remain one-way and fail-static. The only reverse message
/// is a typed guest-identity mint request: bearer credentials cannot be pushed
/// in snapshots or persisted, and the namespace child must not receive the
/// parent agent's control-plane credentials.
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

/// Listener-side request/reply adapter over the child's stdout and stdin.
public actor MetadataIdentityIPCClient {
    private let output: FileHandle
    private var pending: [UUID: CheckedContinuation<GuestJWTSVIDResponse, Error>] = [:]

    public init(output: FileHandle) {
        self.output = output
    }

    public func mint(vmId: UUID, audience: String, ttlSeconds: Int) async throws -> GuestJWTSVIDResponse {
        let request = MetadataIdentityRequest(
            requestId: UUID(), vmId: vmId, audience: audience, ttlSeconds: ttlSeconds)
        let frame = try MetadataControlProtocol.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.requestId] = continuation
            do {
                try output.write(contentsOf: frame)
            } catch {
                pending.removeValue(forKey: request.requestId)
                continuation.resume(throwing: error)
            }
        }
    }

    public func receive(_ response: MetadataIdentityResponse) {
        guard let continuation = pending.removeValue(forKey: response.requestId) else { return }
        guard let svid = response.svid else {
            continuation.resume(throwing: GuestIdentityMintingError.unavailable)
            return
        }
        continuation.resume(returning: svid)
    }

    public func finish() {
        let continuations = Array(pending.values)
        pending = [:]
        for continuation in continuations {
            continuation.resume(throwing: GuestIdentityMintingError.unavailable)
        }
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
