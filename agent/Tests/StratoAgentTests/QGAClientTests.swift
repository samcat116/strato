import Foundation
import Logging
import Testing

@testable import StratoAgentCore

/// Behavioral coverage for `QGAClient` against an in-memory fake guest agent
/// (issue #563): the `guest-sync-delimited` handshake, typed command replies,
/// the shutdown-drops-connection path, error propagation, and the qga →
/// `GuestInfo` mapping — all without a real socket.
@Suite("QGA Client")
struct QGAClientTests {

    // MARK: - Fake guest agent

    /// What the fake agent does with a parsed request.
    enum Reply: Sendable {
        /// Reply with these bytes (the fake prepends the `0xFF` marker itself
        /// for `guest-sync-delimited`).
        case object([UInt8])
        /// Drop the connection instead of replying (models a guest powering off
        /// mid-`guest-shutdown`, or a hung agent that closes).
        case close
    }

    /// Records every `execute` seen across channels, guarded by a scoped lock
    /// (safe to touch from the fake's actor-isolated methods).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func record(_ execute: String) { lock.withLock { items.append(execute) } }
        var all: [String] { lock.withLock { items } }
    }

    /// A transport whose channels answer requests from a caller-supplied
    /// handler.
    final class FakeQGATransport: QGATransport, @unchecked Sendable {
        let handler: @Sendable (_ execute: String, _ syncId: Int?) -> Reply
        /// Bytes per `readSome()` — set small to exercise the framer's
        /// reassembly across partial reads. `nil` returns everything at once.
        let chunkSize: Int?
        let recorder = Recorder()

        init(chunkSize: Int? = nil, handler: @escaping @Sendable (String, Int?) -> Reply) {
            self.handler = handler
            self.chunkSize = chunkSize
        }

        var executes: [String] { recorder.all }

        func openChannel() async throws -> any QGAByteChannel {
            FakeQGAChannel(handler: handler, chunkSize: chunkSize, recorder: recorder)
        }
    }

    /// One fake connection. An actor so its buffers need no manual locking.
    actor FakeQGAChannel: QGAByteChannel {
        private let handler: @Sendable (String, Int?) -> Reply
        private let chunkSize: Int?
        private let recorder: Recorder
        private var writeAccumulator: [UInt8] = []
        private var readBuffer: [UInt8] = []

        init(handler: @escaping @Sendable (String, Int?) -> Reply, chunkSize: Int?, recorder: Recorder) {
            self.handler = handler
            self.chunkSize = chunkSize
            self.recorder = recorder
        }

        func write(_ bytes: [UInt8]) async throws {
            writeAccumulator.append(contentsOf: bytes)
            // Extract each complete JSON object the client wrote (skipping the
            // leading 0xFF the sync carries) and enqueue its reply.
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
            let syncId = (json?["arguments"] as? [String: Any])?["id"] as? Int
            recorder.record(execute)

            switch handler(execute, syncId) {
            case .object(var bytes):
                if execute == "guest-sync-delimited" {
                    bytes = [0xFF] + bytes  // the delimited reply is 0xFF-prefixed
                }
                readBuffer.append(contentsOf: bytes)
            case .close:
                readBuffer.removeAll(keepingCapacity: true)  // nothing more to read → EOF
            }
        }

        func readSome() async throws -> [UInt8] {
            // The fake is synchronous: a reply is enqueued by the time the
            // client reads, so no continuation parking is needed.
            guard !readBuffer.isEmpty else { return [] }  // closed or nothing pending → EOF
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

    private static func returnObject(_ json: String) -> [UInt8] { Array(#"{"return": \#(json)}"#.utf8) }

    /// A handler covering the common healthy replies. Interfaces/hostname are
    /// injected so individual tests can vary them.
    private static func healthyHandler(
        hostName: String = "web01",
        interfacesJSON: String = "[]",
        shutdownDropsConnection: Bool = false
    ) -> @Sendable (String, Int?) -> Reply {
        { execute, syncId in
            switch execute {
            case "guest-sync-delimited":
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            case "guest-ping":
                return .object(returnObject("{}"))
            case "guest-fsfreeze-freeze":
                return .object(returnObject("2"))
            case "guest-fsfreeze-thaw":
                return .object(returnObject("2"))
            case "guest-get-host-name":
                return .object(returnObject(#"{"host-name": "\#(hostName)"}"#))
            case "guest-network-get-interfaces":
                return .object(returnObject(interfacesJSON))
            case "guest-shutdown":
                return shutdownDropsConnection ? .close : .object(returnObject("{}"))
            default:
                return .object(Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
            }
        }
    }

    private func makeClient(_ transport: FakeQGATransport) -> QGAClient {
        QGAClient(transport: transport, logger: Logger(label: "test.qga"))
    }

    // MARK: - Tests

    @Test("ping succeeds against a responsive agent and drives a sync first")
    func pingSucceeds() async throws {
        let transport = FakeQGATransport(handler: Self.healthyHandler())
        try await makeClient(transport).ping()
        #expect(transport.executes == ["guest-sync-delimited", "guest-ping"])
    }

    @Test("ping reassembles replies delivered one byte at a time")
    func pingWithTinyChunks() async throws {
        let transport = FakeQGATransport(chunkSize: 1, handler: Self.healthyHandler())
        try await makeClient(transport).ping()
        #expect(transport.executes == ["guest-sync-delimited", "guest-ping"])
    }

    @Test("freeze and thaw return the filesystem counts qga reports")
    func freezeThaw() async throws {
        let transport = FakeQGATransport(handler: Self.healthyHandler())
        let client = makeClient(transport)
        #expect(try await client.freezeFilesystems() == 2)
        #expect(try await client.thawFilesystems() == 2)
    }

    @Test("shutdown treats a mid-command connection drop as success")
    func shutdownConnectionDrop() async throws {
        let transport = FakeQGATransport(
            handler: Self.healthyHandler(shutdownDropsConnection: true))
        // Must not throw: the sync proved liveness, and the guest dropping the
        // connection as it powers off is the expected outcome.
        try await makeClient(transport).requestShutdown()
        #expect(transport.executes == ["guest-sync-delimited", "guest-shutdown"])
    }

    @Test("a sync-token mismatch fails the operation")
    func syncMismatch() async throws {
        let transport = FakeQGATransport { execute, _ in
            // Always echo the wrong token.
            .object(Array(#"{"return": 999999}"#.utf8))
        }
        await #expect(throws: QGAClient.QGAError.syncMismatch) {
            try await makeClient(transport).ping()
        }
    }

    @Test("a qga error object surfaces as a commandError")
    func commandErrorSurfaces() async throws {
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(Array(#"{"error": {"class": "GenericError", "desc": "no freezable fs"}}"#.utf8))
        }
        await #expect(throws: QGAClient.QGAError.self) {
            _ = try await makeClient(transport).freezeFilesystems()
        }
    }

    @Test("collectGuestInfo maps hostname and per-MAC addresses into GuestInfo")
    func collectGuestInfoMapping() async throws {
        let interfacesJSON = """
            [
              {"name":"lo","hardware-address":"00:00:00:00:00:00",
               "ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1","prefix":8}]},
              {"name":"enp0s3","hardware-address":"52:54:00:AB:CD:EF",
               "ip-addresses":[
                 {"ip-address-type":"ipv4","ip-address":"10.0.0.5","prefix":24},
                 {"ip-address-type":"ipv6","ip-address":"fe80::5054:ff:feab:cdef","prefix":64}
               ]},
              {"name":"noaddr"}
            ]
            """
        let transport = FakeQGATransport(
            handler: Self.healthyHandler(hostName: "app-7", interfacesJSON: interfacesJSON))
        let info = try await makeClient(transport).collectGuestInfo()

        #expect(info.qgaAvailable)
        #expect(info.hostname == "app-7")
        #expect(info.interfaces.count == 3)

        let eth = try #require(info.interfaces.first { $0.name == "enp0s3" })
        // MAC is lowercased for case-insensitive control-plane matching.
        #expect(eth.hardwareAddress == "52:54:00:ab:cd:ef")
        #expect(eth.addresses.count == 2)
        #expect(eth.addresses.contains { $0.family == .ipv4 && $0.address == "10.0.0.5" && $0.prefixLength == 24 })
        #expect(eth.addresses.contains { $0.family == .ipv6 && $0.prefixLength == 64 })

        // An interface qga reported without ip-addresses maps to an empty list.
        let noaddr = try #require(info.interfaces.first { $0.name == "noaddr" })
        #expect(noaddr.addresses.isEmpty)
    }

    @Test("collectGuestInfo still reports availability when detail queries fail")
    func collectGuestInfoDegrades() async throws {
        // Only the sync succeeds; hostname/interfaces come back as errors.
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(Array(#"{"error": {"class": "GenericError", "desc": "unsupported"}}"#.utf8))
        }
        let info = try await makeClient(transport).collectGuestInfo()
        #expect(info.qgaAvailable)
        #expect(info.hostname == nil)
        #expect(info.interfaces.isEmpty)
    }

    @Test("a channel that never syncs (EOF) throws rather than hanging")
    func unresponsiveAgent() async throws {
        // Every request drops the connection: models a guest with no qga.
        let transport = FakeQGATransport { _, _ in .close }
        await #expect(throws: QGAClient.QGAError.connectionClosed) {
            try await makeClient(transport).ping()
        }
    }
}
