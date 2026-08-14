import Foundation
import Synchronization
import Testing

@testable import StratoAgentCore

private final class RecordingDurableFileSystemCalls: DurableFileSystemCalls, Sendable {
    enum Event: Equatable, Sendable {
        case pathStatus(String)
        case createDirectory(String, permissions: CInt)
        case remove(String)
        case create(String, permissions: CInt)
        case openFile(String)
        case openDirectory(String)
        case write(Data, fileDescriptor: CInt)
        case synchronizeFile(CInt)
        case synchronizeDirectory(CInt)
        case close(CInt)
        case replace(source: String, destination: String)
    }

    private struct State: Sendable {
        var events: [Event] = []
        var fileSynchronizationFails = false
        var existingDirectories: Set<String>
    }

    private let state: Mutex<State>
    let errorNumber: CInt = 5

    init(existingDirectories: Set<String> = ["/state"]) {
        self.state = Mutex(
            State(
                existingDirectories: existingDirectories))
    }

    var events: [Event] {
        state.withLock { $0.events }
    }

    func failFileSynchronization() {
        state.withLock { $0.fileSynchronizationFails = true }
    }

    func pathStatus(at path: String) -> DurablePathStatus {
        state.withLock {
            $0.events.append(.pathStatus(path))
            return $0.existingDirectories.contains(path) ? .directory : .missing
        }
    }

    func createDirectory(at path: String, permissions: CInt) -> CInt {
        state.withLock {
            $0.events.append(.createDirectory(path, permissions: permissions))
            $0.existingDirectories.insert(path)
        }
        return 0
    }

    func removeItem(at path: String) -> CInt {
        record(.remove(path))
        return 0
    }

    func createFile(at path: String, permissions: CInt) -> CInt {
        record(.create(path, permissions: permissions))
        return 10
    }

    func openFileForSynchronization(at path: String) -> CInt {
        record(.openFile(path))
        return 10
    }

    func openDirectoryForSynchronization(at path: String) -> CInt {
        record(.openDirectory(path))
        return 20
    }

    func write(_ data: Data, to fileDescriptor: CInt) throws {
        record(.write(data, fileDescriptor: fileDescriptor))
    }

    func synchronizeFile(_ fileDescriptor: CInt) -> CInt {
        record(.synchronizeFile(fileDescriptor))
        return state.withLock { $0.fileSynchronizationFails ? -1 : 0 }
    }

    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt {
        record(.synchronizeDirectory(fileDescriptor))
        return 0
    }

    func close(_ fileDescriptor: CInt) -> CInt {
        record(.close(fileDescriptor))
        return 0
    }

    func replaceItem(at destination: String, withItemAt source: String) -> CInt {
        record(.replace(source: source, destination: destination))
        return 0
    }

    private func record(_ event: Event) {
        state.withLock { $0.events.append(event) }
    }
}

@Suite("Durable file writer")
struct DurableFileWriterTests {
    @Test("Atomic writes synchronize bytes before rename and the directory after")
    func writeOrdering() throws {
        let calls = RecordingDurableFileSystemCalls()
        let writer = DurableFileWriter(systemCalls: calls)
        let data = Data("manifest".utf8)

        try writer.write(data, to: "/state/manifest.json", permissions: 0o600)

        #expect(
            calls.events == [
                .pathStatus("/state"),
                .remove("/state/manifest.json.tmp"),
                .create("/state/manifest.json.tmp", permissions: 0o600),
                .write(data, fileDescriptor: 10),
                .synchronizeFile(10),
                .close(10),
                .replace(
                    source: "/state/manifest.json.tmp",
                    destination: "/state/manifest.json"),
                .openDirectory("/state"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("Every newly created directory is synchronized through its parent")
    func newDirectoryOrdering() throws {
        let calls = RecordingDurableFileSystemCalls(existingDirectories: ["/root"])
        let writer = DurableFileWriter(systemCalls: calls)
        let data = Data("manifest".utf8)

        try writer.write(data, to: "/root/state/records/manifest.json")

        #expect(
            calls.events == [
                .pathStatus("/root/state/records"),
                .pathStatus("/root/state"),
                .pathStatus("/root"),
                .createDirectory("/root/state", permissions: 0o777),
                .openDirectory("/root"),
                .synchronizeDirectory(20),
                .close(20),
                .createDirectory("/root/state/records", permissions: 0o777),
                .openDirectory("/root/state"),
                .synchronizeDirectory(20),
                .close(20),
                .remove("/root/state/records/manifest.json.tmp"),
                .create("/root/state/records/manifest.json.tmp", permissions: 0o666),
                .write(data, fileDescriptor: 10),
                .synchronizeFile(10),
                .close(10),
                .replace(
                    source: "/root/state/records/manifest.json.tmp",
                    destination: "/root/state/records/manifest.json"),
                .openDirectory("/root/state/records"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("Publishing an existing staging file has the same durability ordering")
    func publishOrdering() throws {
        let calls = RecordingDurableFileSystemCalls()
        let writer = DurableFileWriter(systemCalls: calls)

        try writer.publish(stagingPath: "/vol/disk.partial", to: "/vol/disk.raw")

        #expect(
            calls.events == [
                .openFile("/vol/disk.partial"),
                .synchronizeFile(10),
                .close(10),
                .replace(source: "/vol/disk.partial", destination: "/vol/disk.raw"),
                .openDirectory("/vol"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("A file synchronization failure never publishes the temporary bytes")
    func synchronizationFailureDoesNotRename() {
        let calls = RecordingDurableFileSystemCalls()
        calls.failFileSynchronization()
        let writer = DurableFileWriter(systemCalls: calls)

        #expect(throws: DurableFileWriteError.self) {
            try writer.write(Data("state".utf8), to: "/state/manifest.json")
        }

        #expect(
            !calls.events.contains { event in
                if case .replace = event { return true }
                return false
            })
        #expect(calls.events.last == .remove("/state/manifest.json.tmp"))
    }
}
