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
        case openDirectory(String)
        case write(Data, fileDescriptor: CInt)
        case synchronizeFile(CInt)
        case synchronizeFileAt(String)
        case directoryEntries(String)
        case synchronizeDirectory(CInt)
        case close(CInt)
        case replace(source: String, destination: String)
    }

    private struct State: Sendable {
        var events: [Event] = []
        var overlappingWrite: (@Sendable () throws -> Void)?
        var modelFiles = false
        var nextDescriptor: CInt = 10
        var paths: [String: CInt] = [:]
        var contents: [CInt: Data] = [:]
        var publications: [Data] = []
        var fileSynchronizationFails = false
        var failureOperation: String?
        var existingDirectories: Set<String>
        var directoryEntries: [String: [DurableDirectoryEntry]] = [:]
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

    var publications: [Data] { state.withLock { $0.publications } }

    func overlapFirstWrite(with operation: @escaping @Sendable () throws -> Void) {
        state.withLock {
            $0.modelFiles = true
            $0.overlappingWrite = operation
        }
    }

    var createdPaths: [String] {
        events.compactMap { event in
            if case .create(let path, _) = event { return path }
            return nil
        }
    }

    func fail(_ operation: String) {
        state.withLock { $0.failureOperation = operation }
    }

    func failFileSynchronization() {
        state.withLock { $0.fileSynchronizationFails = true }
    }

    func setDirectoryEntries(_ entries: [DurableDirectoryEntry], at path: String) {
        state.withLock { $0.directoryEntries[path] = entries }
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
        state.withLock {
            $0.events.append(.remove(path))
            $0.paths.removeValue(forKey: path)
        }
        return 0
    }

    func createFile(at path: String, permissions: CInt) -> CInt {
        state.withLock {
            $0.events.append(.create(path, permissions: permissions))
            if $0.failureOperation == "create" { return -1 }
            guard $0.paths[path] == nil else { return -1 }
            let descriptor = $0.nextDescriptor
            $0.nextDescriptor += 1
            $0.paths[path] = descriptor
            $0.contents[descriptor] = Data()
            return descriptor
        }
    }

    func openDirectoryForSynchronization(at path: String) -> CInt {
        record(.openDirectory(path))
        return 20
    }

    func write(_ data: Data, to fileDescriptor: CInt) throws {
        let overlap = state.withLock {
            let operation = $0.overlappingWrite
            $0.overlappingWrite = nil
            return operation
        }
        try overlap?()
        if state.withLock({ $0.failureOperation == "write" }) {
            throw DurableFileWriteError(operation: "write", path: "descriptor", errorNumber: errorNumber)
        }
        state.withLock {
            $0.events.append(.write(data, fileDescriptor: fileDescriptor))
            $0.contents[fileDescriptor] = data
        }
    }

    func synchronizeFile(_ fileDescriptor: CInt, at path: String) throws {
        record(.synchronizeFile(fileDescriptor))
        if state.withLock({ $0.fileSynchronizationFails }) {
            throw DurableFileWriteError(operation: "synchronize", path: path, errorNumber: errorNumber)
        }
    }

    func synchronizeFile(at path: String) throws {
        record(.synchronizeFileAt(path))
        if state.withLock({ $0.fileSynchronizationFails }) {
            throw DurableFileWriteError(operation: "synchronize", path: path, errorNumber: errorNumber)
        }
    }

    func directoryEntries(at path: String) throws -> [DurableDirectoryEntry] {
        state.withLock {
            $0.events.append(.directoryEntries(path))
            return $0.directoryEntries[path] ?? []
        }
    }

    func synchronizeDirectory(_ fileDescriptor: CInt) -> CInt {
        record(.synchronizeDirectory(fileDescriptor))
        return state.withLock { $0.failureOperation == "directory sync" ? -1 : 0 }
    }

    func close(_ fileDescriptor: CInt) -> CInt {
        record(.close(fileDescriptor))
        return state.withLock { $0.failureOperation == "close" && fileDescriptor == 10 ? -1 : 0 }
    }

    func replaceItem(at destination: String, withItemAt source: String) -> CInt {
        state.withLock {
            $0.events.append(.replace(source: source, destination: destination))
            if $0.failureOperation == "rename" { return -1 }
            guard $0.modelFiles else { return 0 }
            guard let descriptor = $0.paths.removeValue(forKey: source) else { return -1 }
            $0.paths[destination] = descriptor
            $0.publications.append($0.contents[descriptor] ?? Data())
            return 0
        }
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

        let temporaryPath = try #require(calls.createdPaths.first)
        #expect(temporaryPath.hasPrefix("/state/manifest.json.tmp."))
        #expect(
            calls.events == [
                .pathStatus("/state"),
                .create(temporaryPath, permissions: 0o600),
                .write(data, fileDescriptor: 10),
                .synchronizeFile(10),
                .close(10),
                .replace(
                    source: temporaryPath,
                    destination: "/state/manifest.json"),
                .openDirectory("/state"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("An overlapping writer cannot unlink or consume another writer's staging inode")
    func overlappingWritesOwnTheirStagingFiles() throws {
        let calls = RecordingDurableFileSystemCalls()
        let writer = DurableFileWriter(systemCalls: calls)
        let first = Data("first complete payload".utf8)
        let second = Data("second complete payload".utf8)
        // A has opened its staging inode when B runs to completion. With the
        // old shared name B unlinks A's inode and consumes the shared entry,
        // leaving A's rename to fail despite having synchronized its bytes.
        calls.overlapFirstWrite {
            try writer.write(second, to: "/state/manifest.json")
        }

        try writer.write(first, to: "/state/manifest.json")

        #expect(Set(calls.createdPaths).count == 2)
        #expect(calls.publications == [second, first])
        #expect(
            !calls.events.contains {
                if case .remove = $0 { return true }; return false
            })
    }

    @Test("An overlapping failed writer cleans only its staging file")
    func overlappingFailurePreservesOtherWriter() throws {
        let calls = RecordingDurableFileSystemCalls()
        let writer = DurableFileWriter(systemCalls: calls)
        let payload = Data("successful complete payload".utf8)
        calls.overlapFirstWrite {
            calls.fail("rename")
            #expect(throws: DurableFileWriteError.self) {
                try writer.write(Data("failed payload".utf8), to: "/state/manifest.json")
            }
            calls.fail("")
        }

        try writer.write(payload, to: "/state/manifest.json")

        #expect(calls.createdPaths.count == 2)
        #expect(Set(calls.createdPaths).count == 2)
        #expect(calls.publications == [payload])
        let failedStaging = try #require(calls.createdPaths.last)
        #expect(
            calls.events.filter {
                if case .remove = $0 { return true }; return false
            } == [.remove(failedStaging)])
    }

    @Test("Concurrent real writers publish complete payloads and leave no staging files")
    func concurrentWriters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let path = root.appendingPathComponent("state").path
        let payloads = (0..<16).map { Data(repeating: UInt8($0), count: 128 * 1024) }
        let writer = DurableFileWriter()
        try writer.write(payloads[0], to: path, permissions: 0o600)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    try writer.write(payload, to: path, permissions: 0o600)
                    let observed = try Data(contentsOf: URL(fileURLWithPath: path))
                    #expect(payloads.contains(observed))
                }
            }
            try await group.waitForAll()
        }
        #expect(payloads.contains(try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state"])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Every newly created directory is synchronized through its parent")
    func newDirectoryOrdering() throws {
        let calls = RecordingDurableFileSystemCalls(existingDirectories: ["/root"])
        let writer = DurableFileWriter(systemCalls: calls)
        let data = Data("manifest".utf8)

        try writer.write(data, to: "/root/state/records/manifest.json")

        let temporaryPath = try #require(calls.createdPaths.first)
        #expect(temporaryPath.hasPrefix("/root/state/records/manifest.json.tmp."))
        #expect(
            calls.events == [
                .pathStatus("/root/state/records"),
                .pathStatus("/root/state"),
                .pathStatus("/root"),
                .createDirectory("/root/state", permissions: 0o700),
                .openDirectory("/root"),
                .synchronizeDirectory(20),
                .close(20),
                .createDirectory("/root/state/records", permissions: 0o700),
                .openDirectory("/root/state"),
                .synchronizeDirectory(20),
                .close(20),
                .create(temporaryPath, permissions: 0o600),
                .write(data, fileDescriptor: 10),
                .synchronizeFile(10),
                .close(10),
                .replace(
                    source: temporaryPath,
                    destination: "/root/state/records/manifest.json"),
                .openDirectory("/root/state/records"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("Directory creation preserves unresolved dot-dot components")
    func unresolvedParentComponent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-directory-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let stagingDirectory = root.appendingPathComponent("staging")
        let targetPath =
            stagingDirectory
            .appendingPathComponent("..")
            .appendingPathComponent("volumes")
            .path

        try DurableFileWriter().createDirectory(at: targetPath)

        #expect(FileManager.default.fileExists(atPath: stagingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("volumes").path))
    }

    @Test("Publishing an existing staging file has the same durability ordering")
    func publishOrdering() throws {
        let calls = RecordingDurableFileSystemCalls()
        let writer = DurableFileWriter(systemCalls: calls)

        try writer.publish(stagingPath: "/vol/disk.partial", to: "/vol/disk.raw")

        #expect(
            calls.events == [
                .synchronizeFileAt("/vol/disk.partial"),
                .replace(source: "/vol/disk.partial", destination: "/vol/disk.raw"),
                .openDirectory("/vol"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("Directory publication synchronizes every payload before its completion sidecar and rename")
    func publishDirectoryOrdering() throws {
        let calls = RecordingDurableFileSystemCalls()
        calls.setDirectoryEntries(
            [
                DurableDirectoryEntry(path: "/cache/item/rootfs.ext4", kind: .file),
                DurableDirectoryEntry(path: "/cache/item/config.json", kind: .file),
                DurableDirectoryEntry(path: "/cache/item/nested", kind: .directory),
                DurableDirectoryEntry(path: "/cache/item/nested/state", kind: .file),
                DurableDirectoryEntry(path: "/cache/item/completion.json", kind: .file),
            ],
            at: "/cache/item")
        let writer = DurableFileWriter(systemCalls: calls)

        try writer.publishDirectory(
            stagingPath: "/cache/item", to: "/cache/published",
            completionFileName: "completion.json")

        #expect(
            calls.events == [
                .directoryEntries("/cache/item"),
                .synchronizeFileAt("/cache/item/config.json"),
                .synchronizeFileAt("/cache/item/nested/state"),
                .synchronizeFileAt("/cache/item/rootfs.ext4"),
                .openDirectory("/cache/item/nested"),
                .synchronizeDirectory(20),
                .close(20),
                .synchronizeFileAt("/cache/item/completion.json"),
                .openDirectory("/cache/item"),
                .synchronizeDirectory(20),
                .close(20),
                .replace(source: "/cache/item", destination: "/cache/published"),
                .openDirectory("/cache"),
                .synchronizeDirectory(20),
                .close(20),
            ])
    }

    @Test("A directory payload synchronization failure never publishes the directory")
    func directoryPayloadSynchronizationFailureDoesNotRename() {
        let calls = RecordingDurableFileSystemCalls()
        calls.setDirectoryEntries(
            [
                DurableDirectoryEntry(path: "/cache/item/rootfs.ext4", kind: .file),
                DurableDirectoryEntry(path: "/cache/item/completion.json", kind: .file),
            ],
            at: "/cache/item")
        calls.failFileSynchronization()
        let writer = DurableFileWriter(systemCalls: calls)

        #expect(throws: DurableFileWriteError.self) {
            try writer.publishDirectory(
                stagingPath: "/cache/item", to: "/cache/published",
                completionFileName: "completion.json")
        }

        #expect(
            calls.events == [
                .directoryEntries("/cache/item"),
                .synchronizeFileAt("/cache/item/rootfs.ext4"),
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
        #expect(calls.createdPaths.count == 1)
        #expect(calls.events.last == calls.createdPaths.first.map { .remove($0) })
    }

    @Test(
        "Failure cleanup removes only owned unpublished staging files",
        arguments: ["create", "write", "close", "rename", "directory sync"])
    func failureCleanup(operation: String) throws {
        let calls = RecordingDurableFileSystemCalls()
        calls.fail(operation)
        let writer = DurableFileWriter(systemCalls: calls)

        #expect(throws: DurableFileWriteError.self) {
            try writer.write(Data("state".utf8), to: "/state/manifest.json", permissions: 0o600)
        }

        let staging = try #require(calls.createdPaths.first)
        let removals = calls.events.compactMap { event -> String? in
            if case .remove(let path) = event { return path }
            return nil
        }
        #expect(removals == (operation == "create" || operation == "directory sync" ? [] : [staging]))
        #expect(calls.events.filter { $0 == .close(10) }.count == (operation == "create" ? 0 : 1))
        if operation == "directory sync" {
            #expect(calls.events.contains(.replace(source: staging, destination: "/state/manifest.json")))
        }
    }

    @Test("A staged file synchronization failure never publishes the file")
    func stagedFileSynchronizationFailureDoesNotRename() {
        let calls = RecordingDurableFileSystemCalls()
        calls.failFileSynchronization()
        let writer = DurableFileWriter(systemCalls: calls)

        #expect(throws: DurableFileWriteError.self) {
            try writer.publish(stagingPath: "/vol/disk.partial", to: "/vol/disk.raw")
        }

        #expect(calls.events == [.synchronizeFileAt("/vol/disk.partial")])
    }
}
