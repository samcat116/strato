import Foundation
import Logging
import StratoShared

/// A minimal QMP client for read-mostly probes against a VM's dedicated
/// stats monitor socket (issue #567).
///
/// SwiftQEMU's `QMPClient` drives the lifecycle monitor it owns, but its
/// command vocabulary is a closed enum without `qom-get`/`qom-set`, and each
/// QMP server socket admits one client at a time — so balloon statistics get
/// their own deterministic monitor socket (see `QEMUService.statsSocketPath`)
/// and this client, built on the same byte-channel/framing infrastructure as
/// `QGAClient` so it is unit-testable against an in-memory fake.
///
/// Unlike qga, QMP opens with a `{"QMP": ...}` greeting and requires a
/// `qmp_capabilities` handshake before any command; replies can interleave
/// with asynchronous `{"event": ...}` notifications, which are skipped. Every
/// operation opens (and closes) its own channel, and callers must bound each
/// call with a `StageBudget` — the guest being slow or the socket being
/// wedged is a normal outcome, not an exceptional one.
public actor QMPProbeClient {
    public enum QMPProbeError: Error, LocalizedError, Equatable {
        /// The channel reached EOF before a complete reply arrived.
        case connectionClosed
        /// The stream didn't open with a QMP greeting, or a reply decoded
        /// without the expected `return` value.
        case malformedResponse
        /// QMP answered with an `{"error": ...}` object.
        case commandError(String)

        public var errorDescription: String? {
            switch self {
            case .connectionClosed: return "QMP channel closed before a complete reply"
            case .malformedResponse: return "QMP reply missing its greeting or return value"
            case .commandError(let desc): return desc
            }
        }
    }

    private let transport: any QGATransport
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: any QGATransport, logger: Logger) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: - High-level operations

    /// Collects the guest's balloon memory statistics: enables guest stats
    /// polling on the balloon device (`qom-set guest-stats-polling-interval`,
    /// idempotent), then reads `qom-get guest-stats`.
    ///
    /// Returns nil — not an error — when the VM has no balloon device at
    /// `balloonPath` (a VM created before the device was attached) or the
    /// guest's virtio_balloon driver hasn't reported yet (stats are `-1`
    /// until the first guest update). Throws only for channel-level failures.
    public func collectMemoryStats(
        balloonPath: String = "/machine/peripheral/balloon0",
        pollingIntervalSeconds: Int = 10
    ) async throws -> VMMemoryStats? {
        try await withChannel { channel, framer in
            try await self.negotiate(channel, framer)

            do {
                _ = try await self.command(
                    channel, framer, execute: "qom-set",
                    arguments: QMPProbe.QOMSetArguments(
                        path: balloonPath,
                        property: "guest-stats-polling-interval",
                        value: pollingIntervalSeconds),
                    as: QMPProbe.Empty.self)
            } catch QMPProbeError.commandError {
                // No balloon device at that path — QEMU rejects the qom-set.
                // Normal for VMs created before the device was attached.
                return nil
            }

            let reply: QMPProbe.GuestStats
            do {
                reply = try await self.command(
                    channel, framer, execute: "qom-get",
                    arguments: QMPProbe.QOMGetArguments(
                        path: balloonPath, property: "guest-stats"),
                    as: QMPProbe.GuestStats.self)
            } catch QMPProbeError.commandError {
                return nil
            }

            // `last-update == 0` means the guest driver has never answered a
            // stats request; individual stats are -1 (dropped to nil by the
            // tolerant decoder) until reported. Absence of the load-bearing
            // pair means there is nothing truthful to report.
            guard (reply.lastUpdate ?? 0) > 0,
                let total = reply.stats["stat-total-memory"] ?? nil,
                let available = reply.stats["stat-available-memory"] ?? nil
            else { return nil }

            return VMMemoryStats(
                totalBytes: total,
                availableBytes: available,
                freeBytes: reply.stats["stat-free-memory"] ?? nil
            )
        }
    }

    // MARK: - Channel lifecycle

    /// Opens a channel, runs `body`, and closes the channel whether or not
    /// `body` throws.
    private func withChannel<T>(
        _ body: (any QGAByteChannel, QGAObjectFramer) async throws -> T
    ) async throws -> T {
        let channel = try await transport.openChannel()
        let framer = QGAObjectFramer()
        do {
            let result = try await body(channel, framer)
            await channel.close()
            return result
        } catch {
            await channel.close()
            throw error
        }
    }

    // MARK: - Protocol primitives

    /// Reads the server greeting and completes the `qmp_capabilities`
    /// handshake, after which the monitor accepts commands.
    private func negotiate(_ channel: any QGAByteChannel, _ framer: QGAObjectFramer) async throws {
        let greetingBytes = try await readNextObject(channel, framer)
        guard (try? decoder.decode(QMPProbe.Greeting.self, from: Data(greetingBytes))) != nil else {
            throw QMPProbeError.malformedResponse
        }
        _ = try await command(
            channel, framer, execute: "qmp_capabilities",
            arguments: QMPProbe.NoArguments?.none, as: QMPProbe.Empty.self)
    }

    /// Sends one command and decodes its `return` value, skipping any
    /// asynchronous event objects that arrive before the reply.
    private func command<Arguments: Encodable, Value: Decodable>(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer,
        execute: String, arguments: Arguments?, as: Value.Type
    ) async throws -> Value {
        var payload = try Array(
            encoder.encode(QMPProbe.Request(execute: execute, arguments: arguments)))
        payload.append(0x0A)
        try await channel.write(payload)

        while true {
            let object = try await readNextObject(channel, framer)
            // QMP interleaves `{"event": ...}` notifications with replies.
            if (try? decoder.decode(QMPProbe.Event.self, from: Data(object)))?.event != nil {
                continue
            }
            let response = try decoder.decode(QMPProbe.Response<Value>.self, from: Data(object))
            if let error = response.error { throw QMPProbeError.commandError(error.description) }
            guard let value = response.return else { throw QMPProbeError.malformedResponse }
            return value
        }
    }

    /// Pulls chunks from the channel until the framer yields one complete JSON
    /// object. Throws `connectionClosed` at EOF.
    private func readNextObject(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer
    ) async throws -> [UInt8] {
        while true {
            if let object = framer.nextObject() { return object }
            let chunk = try await channel.readSome()
            if chunk.isEmpty { throw QMPProbeError.connectionClosed }
            framer.append(chunk)
            if framer.isOverBudget { throw QMPProbeError.malformedResponse }
        }
    }
}

/// The QMP JSON vocabulary this probe speaks. Like `QGA`, these are QEMU's own
/// field names, not Strato's, so they deliberately do not go through
/// `WireProtocol`'s pinned coder pair.
enum QMPProbe {
    /// The `{"QMP": {...}}` object every QMP server sends on connect.
    struct Greeting: Decodable {
        struct Inner: Decodable {}
        // Uppercase key straight from the wire.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let QMP: Inner
    }

    /// A QMP request: `{"execute": "<command>", "arguments": {...}}`.
    struct Request<Arguments: Encodable>: Encodable {
        let execute: String
        let arguments: Arguments?
    }

    /// A QMP reply carrying a typed `return` value, or an `error`.
    struct Response<Value: Decodable>: Decodable {
        let `return`: Value?
        let error: ResponseError?
    }

    /// The `error` object QMP returns when a command fails (e.g. `qom-set`
    /// against a device path that doesn't exist).
    struct ResponseError: Decodable, Error, CustomStringConvertible {
        let `class`: String?
        let desc: String?

        var description: String {
            "QMP error (\(`class` ?? "unknown")): \(desc ?? "no description")"
        }
    }

    /// An asynchronous `{"event": ...}` notification, which can arrive between
    /// a request and its reply and must be skipped.
    struct Event: Decodable {
        let event: String?
    }

    /// Empty-arguments placeholder so `Request`'s generic argument has a
    /// concrete type at call sites that send none.
    struct NoArguments: Encodable {}

    /// Decodable placeholder for commands whose `return` is an empty object.
    struct Empty: Decodable {}

    struct QOMSetArguments: Encodable {
        let path: String
        let property: String
        let value: Int
    }

    struct QOMGetArguments: Encodable {
        let path: String
        let property: String
    }

    /// `qom-get guest-stats` → `{"stats": {"stat-total-memory": N, ...},
    /// "last-update": T}`. Stats the guest never reported are `-1`; the
    /// tolerant `StatValue` maps those (and any out-of-range or non-numeric
    /// value) to nil instead of failing the whole decode.
    struct GuestStats: Decodable {
        let stats: [String: Int64?]
        let lastUpdate: Int64?

        enum CodingKeys: String, CodingKey {
            case stats
            case lastUpdate = "last-update"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decodeIfPresent([String: StatValue].self, forKey: .stats) ?? [:]
            self.stats = raw.mapValues(\.value)
            self.lastUpdate = try container.decodeIfPresent(StatValue.self, forKey: .lastUpdate)?.value
        }
    }

    /// One balloon stat value, decoded tolerantly: negative sentinels (`-1` =
    /// unreported), values beyond `Int64.max` (a guest can theoretically emit
    /// the u64 form of -1), and non-numeric values all become nil.
    struct StatValue: Decodable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let fits = try? container.decode(Int64.self) {
                value = fits >= 0 ? fits : nil
            } else if let wide = try? container.decode(UInt64.self) {
                value = wide <= UInt64(Int64.max) ? Int64(wide) : nil
            } else {
                value = nil
            }
        }
    }
}
