import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Behavioral coverage for `QMPProbeClient` against an in-memory fake QMP
/// monitor (issue #567): the greeting + `qmp_capabilities` handshake, the
/// qom-set/qom-get balloon-stats flow, event skipping, the no-balloon and
/// driver-not-reporting nil outcomes, and sentinel-value tolerance — all
/// without a real socket.
@Suite("QMP Probe Client")
struct QMPProbeClientTests {

    /// What the fake monitor does with a parsed request.
    enum Reply: Sendable {
        /// Reply with these bytes (optionally preceded by unrelated events).
        case object([UInt8])
        /// Drop the connection instead of replying.
        case close
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func record(_ execute: String) { lock.withLock { items.append(execute) } }
        var all: [String] { lock.withLock { items } }
    }

    /// A transport whose channels greet like a QMP server and answer requests
    /// from a caller-supplied handler.
    final class FakeQMPTransport: QGATransport, @unchecked Sendable {
        let handler: @Sendable (_ execute: String) -> Reply
        let greeting: [UInt8]
        /// Bytes per `readSome()` — set small to exercise reassembly.
        let chunkSize: Int?
        let recorder = Recorder()

        init(
            greeting: String = #"{"QMP": {"version": {}, "capabilities": []}}"#,
            chunkSize: Int? = nil,
            handler: @escaping @Sendable (String) -> Reply
        ) {
            self.greeting = Array(greeting.utf8)
            self.chunkSize = chunkSize
            self.handler = handler
        }

        var executes: [String] { recorder.all }

        func openChannel() async throws -> any QGAByteChannel {
            FakeQMPChannel(
                greeting: greeting, handler: handler, chunkSize: chunkSize, recorder: recorder)
        }
    }

    /// One fake connection. The QMP greeting is queued for reading the moment
    /// the channel opens, before the client writes anything — exactly how a
    /// real monitor behaves.
    actor FakeQMPChannel: QGAByteChannel {
        private let handler: @Sendable (String) -> Reply
        private let chunkSize: Int?
        private let recorder: Recorder
        private var writeAccumulator: [UInt8] = []
        private var readBuffer: [UInt8]

        init(
            greeting: [UInt8], handler: @escaping @Sendable (String) -> Reply,
            chunkSize: Int?, recorder: Recorder
        ) {
            self.readBuffer = greeting
            self.handler = handler
            self.chunkSize = chunkSize
            self.recorder = recorder
        }

        func write(_ bytes: [UInt8]) async throws {
            writeAccumulator.append(contentsOf: bytes)
            let framer = QGAObjectFramer()
            framer.append(writeAccumulator)
            writeAccumulator.removeAll(keepingCapacity: true)
            while let object = framer.nextObject() {
                try handle(object)
            }
        }

        private func handle(_ object: [UInt8]) throws {
            let json = try JSONSerialization.jsonObject(with: Data(object)) as? [String: Any]
            let execute = json?["execute"] as? String ?? ""
            recorder.record(execute)

            switch handler(execute) {
            case .object(let bytes):
                readBuffer.append(contentsOf: bytes)
            case .close:
                readBuffer.removeAll(keepingCapacity: true)
            }
        }

        func readSome() async throws -> [UInt8] {
            guard !readBuffer.isEmpty else { return [] }
            if let chunk = chunkSize, chunk < readBuffer.count {
                let head = Array(readBuffer.prefix(chunk))
                readBuffer.removeFirst(chunk)
                return head
            }
            let all = readBuffer
            readBuffer.removeAll(keepingCapacity: true)
            return all
        }

        func close() async {}
    }

    // MARK: - Response builders

    private static let emptyReturn = Array(#"{"return": {}}"#.utf8)

    private static func statsReply(
        total: Int64? = 8_254_390_272,
        available: Int64? = 6_442_450_944,
        free: Int64? = 4_294_967_296,
        lastUpdate: Int64 = 1_752_800_000,
        prefixedEvents: Int = 0
    ) -> [UInt8] {
        var body = ""
        for i in 0..<prefixedEvents {
            body += #"{"event": "BALLOON_CHANGE", "data": {"actual": \#(i)}, "timestamp": {}}"#
        }
        body += #"{"return": {"stats": {"#
        body += #""stat-total-memory": \#(total ?? -1),"#
        body += #""stat-available-memory": \#(available ?? -1),"#
        body += #""stat-free-memory": \#(free ?? -1)"#
        body += #"}, "last-update": \#(lastUpdate)}}"#
        return Array(body.utf8)
    }

    /// A handler for the healthy flow; the qom replies are injectable so
    /// individual tests can vary them.
    private static func healthyHandler(
        qomSetReply: Reply = .object(emptyReturn),
        qomGetReply: Reply = .object(statsReply())
    ) -> @Sendable (String) -> Reply {
        { execute in
            switch execute {
            case "qmp_capabilities":
                return .object(emptyReturn)
            case "qom-set":
                return qomSetReply
            case "qom-get":
                return qomGetReply
            default:
                return .object(Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
            }
        }
    }

    private func collect(_ transport: FakeQMPTransport) async throws -> VMMemoryStats? {
        let client = QMPProbeClient(transport: transport, logger: Logger(label: "test.qmp"))
        return try await client.collectMemoryStats()
    }

    // MARK: - Tests

    @Test("healthy flow negotiates, enables polling, and maps the stats")
    func healthyFlow() async throws {
        let transport = FakeQMPTransport(handler: Self.healthyHandler())
        let collected = try await collect(transport)
        let stats = try #require(collected)
        #expect(stats.totalBytes == 8_254_390_272)
        #expect(stats.availableBytes == 6_442_450_944)
        #expect(stats.freeBytes == 4_294_967_296)
        #expect(transport.executes == ["qmp_capabilities", "qom-set", "qom-get"])
    }

    @Test("replies reassemble when delivered one byte at a time")
    func tinyChunks() async throws {
        let transport = FakeQMPTransport(chunkSize: 1, handler: Self.healthyHandler())
        let collected = try await collect(transport)
        let stats = try #require(collected)
        #expect(stats.totalBytes == 8_254_390_272)
    }

    @Test("async events interleaved before the reply are skipped")
    func eventsSkipped() async throws {
        let transport = FakeQMPTransport(
            handler: Self.healthyHandler(qomGetReply: .object(Self.statsReply(prefixedEvents: 2))))
        let collected = try await collect(transport)
        let stats = try #require(collected)
        #expect(stats.availableBytes == 6_442_450_944)
    }

    @Test("a VM without the balloon device (qom-set error) yields nil, not an error")
    func noBalloonDevice() async throws {
        let transport = FakeQMPTransport(
            handler: Self.healthyHandler(
                qomSetReply: .object(
                    Array(#"{"error": {"class": "DeviceNotFound", "desc": "no balloon0"}}"#.utf8))))
        let collected = try await collect(transport)
        #expect(collected == nil)
        // The probe stops after the failed enable; it never issues the qom-get.
        #expect(transport.executes == ["qmp_capabilities", "qom-set"])
    }

    @Test("a guest driver that never reported (last-update 0) yields nil")
    func driverNeverReported() async throws {
        let transport = FakeQMPTransport(
            handler: Self.healthyHandler(qomGetReply: .object(Self.statsReply(lastUpdate: 0))))
        let collected = try await collect(transport)
        #expect(collected == nil)
    }

    @Test("sentinel -1 stats yield nil rather than fabricated numbers")
    func sentinelStats() async throws {
        let transport = FakeQMPTransport(
            handler: Self.healthyHandler(
                qomGetReply: .object(Self.statsReply(total: nil, available: nil, free: nil))))
        let collected = try await collect(transport)
        #expect(collected == nil)
    }

    @Test("an unreported free stat degrades to nil while the rest survive")
    func partialStats() async throws {
        let transport = FakeQMPTransport(
            handler: Self.healthyHandler(qomGetReply: .object(Self.statsReply(free: nil))))
        let collected = try await collect(transport)
        let stats = try #require(collected)
        #expect(stats.totalBytes == 8_254_390_272)
        #expect(stats.freeBytes == nil)
    }

    @Test("the u64 form of -1 is tolerated as unreported")
    func unsignedSentinel() async throws {
        let reply = Array(
            #"{"return": {"stats": {"stat-total-memory": 8254390272, "stat-available-memory": 6442450944, "stat-free-memory": 18446744073709551615}, "last-update": 1752800000}}"#
                .utf8)
        let transport = FakeQMPTransport(handler: Self.healthyHandler(qomGetReply: .object(reply)))
        let collected = try await collect(transport)
        let stats = try #require(collected)
        #expect(stats.freeBytes == nil)
        #expect(stats.availableBytes == 6_442_450_944)
    }

    @Test("a stream that doesn't open with a QMP greeting fails")
    func missingGreeting() async throws {
        let transport = FakeQMPTransport(
            greeting: #"{"not-qmp": true}"#, handler: Self.healthyHandler())
        await #expect(throws: QMPProbeClient.QMPProbeError.malformedResponse) {
            _ = try await collect(transport)
        }
    }

    @Test("a connection that drops mid-handshake throws rather than hanging")
    func connectionDrop() async throws {
        let transport = FakeQMPTransport { _ in .close }
        await #expect(throws: QMPProbeClient.QMPProbeError.connectionClosed) {
            _ = try await collect(transport)
        }
    }
}
