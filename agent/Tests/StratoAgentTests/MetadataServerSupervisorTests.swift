import Foundation
import Dispatch
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

@Suite("Metadata Server Supervisor Tests")
struct MetadataServerSupervisorTests {

    // MARK: - Doubles

    private final class RecordingHandle: MetadataServerHandle, Sendable {
        private struct State {
            var alive = true
            var pushed: [MetadataSnapshot] = []
            var pushFailure: (any Error)?
        }
        private let state: Mutex<State>

        init(pushFailure: (any Error)? = nil) {
            self.state = Mutex(State(pushFailure: pushFailure))
        }

        var isRunning: Bool {
            state.withLock { $0.alive }
        }

        var snapshots: [MetadataSnapshot] {
            state.withLock { $0.pushed }
        }

        var terminated: Bool {
            state.withLock { !$0.alive }
        }

        /// Simulate the child dying on its own.
        func die() {
            state.withLock { $0.alive = false }
        }

        func push(_ snapshot: MetadataSnapshot) throws {
            let failure = state.withLock { state -> (any Error)? in
                let failure = state.pushFailure
                if failure == nil { state.pushed.append(snapshot) }
                return failure
            }
            if let failure { throw failure }
        }

        func terminate() {
            state.withLock { $0.alive = false }
        }
    }

    private struct SpawnFailure: Error {}

    private final class RecordingSpawner: MetadataServerSpawning, Sendable {
        private struct State {
            var namespaces: Set<UUID>
            var failFor: Set<UUID>
            var pushFailFor: Set<UUID>
            var handles: [UUID: RecordingHandle] = [:]
            var spawnCount = 0
        }
        private let state: Mutex<State>

        var handles: [UUID: RecordingHandle] { state.withLock { $0.handles } }
        var spawnCount: Int { state.withLock { $0.spawnCount } }

        init(namespaces: Set<UUID> = [], failFor: Set<UUID> = [], pushFailFor: Set<UUID> = []) {
            self.state = Mutex(
                State(namespaces: namespaces, failFor: failFor, pushFailFor: pushFailFor))
        }

        func present(_ networkId: UUID) {
            _ = state.withLock { $0.namespaces.insert(networkId) }
        }

        func namespaceExists(networkId: UUID) -> Bool {
            state.withLock { $0.namespaces.contains(networkId) }
        }

        func existingNamespaces() -> [UUID] {
            state.withLock { $0.namespaces.sorted { $0.uuidString < $1.uuidString } }
        }

        func spawn(networkId: UUID) throws -> any MetadataServerHandle {
            try state.withLock { state in
                state.spawnCount += 1
                guard !state.failFor.contains(networkId) else { throw SpawnFailure() }
                let handle = RecordingHandle(
                    pushFailure: state.pushFailFor.contains(networkId) ? SpawnFailure() : nil)
                state.handles[networkId] = handle
                return handle
            }
        }
    }

    private static func supervisor(_ spawner: RecordingSpawner) -> MetadataServerSupervisor {
        MetadataServerSupervisor(spawner: spawner, logger: Logger(label: "test"))
    }

    private static func snapshot(_ networkId: UUID) -> MetadataSnapshot {
        MetadataSnapshot(networkId: networkId, origin: .live, instances: [])
    }

    // MARK: - The pure diff

    @Test("An empty list is an opinion, and stops everything")
    func emptyDesiredStopsAll() async {
        let network = UUID()
        let spawner = RecordingSpawner(namespaces: [network])
        let supervisor = Self.supervisor(spawner)
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)

        await supervisor.reconcile(desired: [], snapshot: Self.snapshot)
        #expect(await supervisor.runningNetworks().isEmpty)
        #expect(spawner.handles[network]?.terminated == true)
    }

    @Test("Starts and stops are derived as a set difference, in a stable order")
    func diffIsASetDifference() {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let actions = MetadataServerReconciler.actions(desired: [second, first], running: [])
        #expect(actions == [.start(networkId: first), .start(networkId: second)])
        #expect(
            MetadataServerReconciler.actions(desired: [first], running: [first, second])
                == [.stop(networkId: second)])
    }

    // MARK: - Lifecycle

    @Test("A network whose namespace is not built yet is deferred, then started")
    func namespaceMustExistFirst() async {
        // The ordinary state on the sync that creates the namespace: the chassis
        // reconcile and this one are separate steps.
        let network = UUID()
        let spawner = RecordingSpawner()
        let supervisor = Self.supervisor(spawner)

        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        #expect(await supervisor.runningNetworks().isEmpty)
        #expect(spawner.spawnCount == 0)

        spawner.present(network)
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        #expect(await supervisor.runningNetworks() == [network])
    }

    @Test("A listener that failed to start is retried on the next sync")
    func failedStartIsRetried() async {
        // Syncs are the retry timer, which is why there is no backoff
        // bookkeeping in the supervisor to get wrong.
        let network = UUID()
        let spawner = RecordingSpawner(namespaces: [network], failFor: [network])
        let supervisor = Self.supervisor(spawner)

        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        #expect(spawner.spawnCount == 2)
        #expect(await supervisor.runningNetworks().isEmpty)
    }

    @Test("A listener that dies on its own is restarted")
    func deadListenerIsRestarted() async {
        let network = UUID()
        let spawner = RecordingSpawner(namespaces: [network])
        let supervisor = Self.supervisor(spawner)
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        let first = spawner.handles[network]

        first?.die()
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)

        #expect(spawner.spawnCount == 2)
        #expect(await supervisor.runningNetworks() == [network])
        #expect(spawner.handles[network] !== first)
    }

    @Test("A listener whose control channel broke is reaped rather than written to forever")
    func brokenChannelIsReaped() async {
        // A child on its way out: the pipe is gone but the process has not been
        // reaped. Left alone, the agent would push into a closed pipe on every
        // sync for as long as that lasted.
        let network = UUID()
        let spawner = RecordingSpawner(namespaces: [network], pushFailFor: [network])
        let supervisor = Self.supervisor(spawner)

        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        #expect(spawner.handles[network]?.terminated == true)
        #expect(await supervisor.runningNetworks().isEmpty)

        // And the next sync starts a replacement.
        await supervisor.reconcile(desired: [network], snapshot: Self.snapshot)
        #expect(spawner.spawnCount == 2)
    }

    // MARK: - Pushes

    @Test("Every running listener is handed its own network's snapshot")
    func snapshotsArePerNetwork() async {
        let first = UUID()
        let second = UUID()
        let spawner = RecordingSpawner(namespaces: [first, second])
        let supervisor = Self.supervisor(spawner)

        await supervisor.reconcile(desired: [first, second], snapshot: Self.snapshot)

        #expect(spawner.handles[first]?.snapshots.map(\.networkId) == [first])
        #expect(spawner.handles[second]?.snapshots.map(\.networkId) == [second])
    }

    @Test("Shutting down terminates every listener")
    func shutdownTerminatesAll() async {
        let first = UUID()
        let second = UUID()
        let spawner = RecordingSpawner(namespaces: [first, second])
        let supervisor = Self.supervisor(spawner)
        await supervisor.reconcile(desired: [first, second], snapshot: Self.snapshot)

        await supervisor.shutdown()

        #expect(await supervisor.runningNetworks().isEmpty)
        #expect(spawner.handles[first]?.terminated == true)
        #expect(spawner.handles[second]?.terminated == true)
    }
}

@Suite("Metadata Server Process Lifecycle Tests")
struct MetadataServerProcessLifecycleTests {
    private static func snapshot() -> MetadataSnapshot {
        MetadataSnapshot(networkId: UUID(), origin: .live, instances: [])
    }

    @Test("Termination force-kills a child blocked in a snapshot write before closing the pipe")
    func terminationInterruptsBlockedWrites() async throws {
        let writeStarted = Mutex(false)
        let writeCount = Mutex(0)
        let processTerminationCount = Mutex(0)
        let forceTerminationCount = Mutex(0)
        let inputCloseCount = Mutex(0)
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        defer { allowWriteToFinish.signal() }

        let io = MetadataServerProcessIO(
            isRunning: { true },
            write: { _ in
                writeStarted.withLock { $0 = true }
                allowWriteToFinish.wait()
                writeCount.withLock { $0 += 1 }
            },
            terminateProcess: { processTerminationCount.withLock { $0 += 1 } },
            forceTerminateProcess: { forceTerminationCount.withLock { $0 += 1 } },
            closeInput: { inputCloseCount.withLock { $0 += 1 } }
        )
        let handle = MetadataServerProcessHandle(
            io: io, networkId: UUID(), logger: Logger(label: "test"),
            terminationGrace: .zero)

        try handle.push(Self.snapshot())
        while !writeStarted.withLock({ $0 }) { await Task.yield() }

        handle.terminate()
        #expect(processTerminationCount.withLock { $0 } == 1)
        for _ in 0..<100 where forceTerminationCount.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(forceTerminationCount.withLock { $0 } == 1)
        #expect(inputCloseCount.withLock { $0 } == 0)
        #expect(!handle.isRunning)
        #expect(throws: (any Error).self) { try handle.push(Self.snapshot()) }

        allowWriteToFinish.signal()
        for _ in 0..<100 where inputCloseCount.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(writeCount.withLock { $0 } == 1)
        #expect(inputCloseCount.withLock { $0 } == 1)

        handle.terminate()
        #expect(processTerminationCount.withLock { $0 } == 1)
        #expect(forceTerminationCount.withLock { $0 } == 1)
        #expect(inputCloseCount.withLock { $0 } == 1)
    }

    @Test("Termination skips SIGKILL when the child exits during the grace period")
    func gracefulTerminationDoesNotEscalate() async throws {
        let isRunning = Mutex(true)
        let forceTerminationCount = Mutex(0)
        let io = MetadataServerProcessIO(
            isRunning: { isRunning.withLock { $0 } },
            write: { _ in },
            terminateProcess: { isRunning.withLock { $0 = false } },
            forceTerminateProcess: { forceTerminationCount.withLock { $0 += 1 } },
            closeInput: {}
        )
        let handle = MetadataServerProcessHandle(
            io: io, networkId: UUID(), logger: Logger(label: "test"),
            terminationGrace: .zero)

        handle.terminate()
        try await Task.sleep(for: .milliseconds(20))

        #expect(forceTerminationCount.withLock { $0 } == 0)
    }
}

@Suite("Metadata Listener Log Relay Tests")
struct MetadataListenerLogRelayTests {

    @Test("A child's line is re-emitted at the level the child chose")
    func tagIsHonored() {
        // Relaying everything at one level would misreport a child's warning as
        // routine, and print the level twice — once as the parent's, once inside
        // the message.
        let (level, message) = MetadataServerProcessHandle.split(line: "warning\tCould not bind the metadata address")
        #expect(level == .warning)
        #expect(message == "Could not bind the metadata address")

        let (debugLevel, debugMessage) = MetadataServerProcessHandle.split(line: "debug\tAdopted a metadata snapshot")
        #expect(debugLevel == .debug)
        #expect(debugMessage == "Adopted a metadata snapshot")
    }

    @Test("An untagged line is kept whole rather than dropped or mangled")
    func untaggedLinesSurvive() {
        // Anything the runtime writes straight to stderr — a crash trace, a
        // loader error — is exactly the output worth keeping.
        let (level, message) = MetadataServerProcessHandle.split(line: "Fatal error: something went wrong")
        #expect(level == .info)
        #expect(message == "Fatal error: something went wrong")

        // A tab with an unrecognized tag is not a tag.
        let (fallback, whole) = MetadataServerProcessHandle.split(line: "loud\tmessage")
        #expect(fallback == .info)
        #expect(whole == "loud\tmessage")
    }
}

@Suite("Metadata Control Protocol Tests")
struct MetadataControlProtocolTests {

    private static func snapshot(instances: Int) -> MetadataSnapshot {
        MetadataSnapshot(
            networkId: UUID(), origin: .live,
            instances: (0..<instances).map { index in
                InstanceMetadata(
                    instanceId: UUID(), hostname: "host-\(index)", projectId: UUID(),
                    serviceEnabled: true)
            })
    }

    @Test("A frame survives being delivered one byte at a time")
    func reassemblesAcrossChunks() throws {
        // A pipe splits wherever it likes, which is the whole reason the frames
        // carry their own length.
        let snapshot = Self.snapshot(instances: 3)
        let frame = try MetadataControlProtocol.encode(snapshot)

        var reader = MetadataFrameReader()
        var decoded: [Data] = []
        for byte in frame {
            decoded.append(contentsOf: try reader.append(Data([byte])))
        }
        #expect(decoded.count == 1)
        #expect(try JSONDecoder().decode(MetadataSnapshot.self, from: decoded[0]) == snapshot)
    }

    @Test("Several frames in one chunk all come out, in order")
    func severalFramesAtOnce() throws {
        let first = Self.snapshot(instances: 1)
        let second = Self.snapshot(instances: 2)
        var stream = try MetadataControlProtocol.encode(first)
        stream.append(try MetadataControlProtocol.encode(second))

        var reader = MetadataFrameReader()
        let frames = try reader.append(stream)
        #expect(frames.count == 2)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(MetadataSnapshot.self, from: frames[0]) == first)
        #expect(try decoder.decode(MetadataSnapshot.self, from: frames[1]) == second)
    }

    @Test("A partial frame yields nothing until it is complete")
    func partialFrameWaits() throws {
        let snapshot = Self.snapshot(instances: 1)
        let frame = try MetadataControlProtocol.encode(snapshot)
        var reader = MetadataFrameReader()

        #expect(try reader.append(frame.prefix(frame.count - 1)).isEmpty)
        #expect(try reader.append(frame.suffix(1)).count == 1)
    }

    @Test("An impossible length is refused rather than waited on")
    func oversizedFrameThrows() {
        // A desynchronized stream would otherwise buffer forever, which looks
        // exactly like a quiet parent.
        var reader = MetadataFrameReader(maxFrameBytes: 16)
        #expect(throws: MetadataControlProtocol.Error.frameTooLarge(bytes: 0x7fff_ffff)) {
            _ = try reader.append(Data([0x7f, 0xff, 0xff, 0xff]))
        }
    }
}
