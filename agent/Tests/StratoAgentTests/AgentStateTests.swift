import Testing
import Foundation
@testable import StratoAgentCore

#if canImport(Glibc)
import Glibc
#endif

@Suite("AgentState Tests")
struct AgentStateTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "agent-state-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeState(token: String = "tok-1") -> AgentState {
        AgentState(
            agentName: "hv-01",
            assignedAgentID: "8B4E1C2A-0000-0000-0000-000000000000",
            controlPlaneURL: "ws://control-plane:8080/agent/ws",
            reconnectToken: token,
            // Whole seconds: ISO8601 persistence drops sub-second precision.
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test("Save and load round-trips the state")
    func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileAgentStateStore(path: dir + "/agent-state.json")

        let state = makeState()
        try store.save(state)

        let loaded = store.load()
        #expect(loaded == state)
    }

    @Test("Load returns nil when the file does not exist")
    func loadMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileAgentStateStore(path: dir + "/agent-state.json")
        #expect(store.load() == nil)
    }

    @Test("State file is written with 0600 permissions")
    func filePermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/agent-state.json"
        let store = FileAgentStateStore(path: path)

        try store.save(makeState())

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test("Save creates missing parent directories with 0700 permissions")
    func createsParentDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nested = dir + "/a/b"
        let store = FileAgentStateStore(path: nested + "/agent-state.json")

        try store.save(makeState())

        #expect(store.load() != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: nested)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o700)
    }

    @Test("Overwriting replaces the previous state atomically")
    func overwrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/agent-state.json"
        let store = FileAgentStateStore(path: path)

        try store.save(makeState(token: "first"))
        try store.save(makeState(token: "second"))

        #expect(store.load()?.reconnectToken == "second")

        // Permissions survive the replace.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        // No leftover temp files from the atomic write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("Repeated overwrites succeed against an existing file (reconnect token rotation)")
    func repeatedOverwrite() throws {
        // Reproduces the run-mode reconnect path: the state file already exists
        // from the initial join, and each rotated token must overwrite it in
        // place. This is where replaceItemAt failed on Linux with "The file
        // doesn't exist".
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/agent-state.json"
        let store = FileAgentStateStore(path: path)

        try store.save(makeState(token: "join"))
        try store.save(makeState(token: "rotated-1"))
        try store.save(makeState(token: "rotated-2"))

        #expect(store.load()?.reconnectToken == "rotated-2")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("ensureWritable creates the directory and leaves no probe behind")
    func ensureWritableCreatesDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nested = dir + "/a/b"
        let store = FileAgentStateStore(path: nested + "/agent-state.json")

        try store.ensureWritable()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested).isEmpty)
    }

    @Test(
        "ensureWritable throws when the directory is not writable",
        // Root bypasses directory permission bits, so the 0o500 chmod below
        // can't make the probe write fail — e.g. in CI's job container.
        .disabled(if: geteuid() == 0, "meaningless when running as root")
    )
    func ensureWritableThrowsOnReadOnlyDirectory() throws {
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            try? FileManager.default.removeItem(atPath: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        let store = FileAgentStateStore(path: dir + "/agent-state.json")

        #expect(throws: (any Error).self) {
            try store.ensureWritable()
        }
    }

    @Test("Corrupt state file is moved aside and load returns nil")
    func corruptFileMovedAside() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/agent-state.json"
        try "not json {".write(toFile: path, atomically: true, encoding: .utf8)
        let store = FileAgentStateStore(path: path)

        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: path + ".corrupt"))

        // A subsequent save starts a fresh state file.
        try store.save(makeState())
        #expect(store.load() != nil)
    }
}
