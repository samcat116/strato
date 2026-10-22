import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import StratoAgentCore

@Suite("Agent state directory ownership")
struct AgentStateDirectoryLockTests {
    private func fixture(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-lock-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    @Test("Contention preserves state; releasing ownership permits restart without replacing the lock inode")
    func restart() throws {
        try fixture { root in
            var owner: AgentStateDirectoryLock? = try AgentStateDirectoryLock(at: root)
            let original = try FileManager.default.attributesOfItem(atPath: root + "/.agent.lock")
            let manifest = Data("existing workload inventory".utf8)
            try manifest.write(to: URL(fileURLWithPath: root + "/vm-manifest.json"))
            #expect(throws: AgentStateDirectoryInUse.self) { try AgentStateDirectoryLock(at: root) }
            #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/vm-manifest.json")) == manifest)
            #expect(try #require(owner).descriptor >= 0)
            owner = nil
            let successor = try AgentStateDirectoryLock(at: root)
            withExtendedLifetime(successor) {
                #expect(throws: AgentStateDirectoryInUse.self) { try AgentStateDirectoryLock(at: root) }
            }
            let current = try FileManager.default.attributesOfItem(atPath: root + "/.agent.lock")
            #expect((original[.systemFileNumber] as? NSNumber) == (current[.systemFileNumber] as? NSNumber))
            #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/vm-manifest.json")) == manifest)
        }
    }

    @Test("The ownership descriptor cannot survive exec")
    func closeOnExec() throws {
        try fixture { root in
            let owner = try AgentStateDirectoryLock(at: root)
            withExtendedLifetime(owner) {
                #expect(fcntl(owner.descriptor, F_GETFD) & FD_CLOEXEC != 0)
            }
        }
    }

    @Test("A symlink or hard-linked ownership file is refused")
    func unsafeLockFile() throws {
        try fixture { root in
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            let target = root + "/operator-file"
            try Data("preserve".utf8).write(to: URL(fileURLWithPath: target))
            let lock = root + "/.agent.lock"
            try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: target)
            #expect(throws: (any Error).self) { try AgentStateDirectoryLock(at: root) }
            try FileManager.default.removeItem(atPath: lock)
            try FileManager.default.linkItem(atPath: target, toPath: lock)
            #expect(throws: (any Error).self) { try AgentStateDirectoryLock(at: root) }
            #expect(try String(contentsOfFile: target, encoding: .utf8) == "preserve")
        }
    }

    // Darwin marks fork unavailable to Swift. Only POSIX calls run in the
    // children: no Foundation, allocation, or Swift test machinery after fork.
    #if os(Linux)
    @Test("A real second process cannot acquire the active agent's lock")
    func competingProcess() throws {
        try fixture { root in
            let owner = try AgentStateDirectoryLock(at: root)
            let inherited = owner.descriptor
            let pid = (root + "/.agent.lock").withCString { path in
                let child = fork()
                if child == 0 {
                    _ = close(inherited)
                    let file = open(path, O_RDWR | O_CLOEXEC)
                    if file < 0 { _exit(90) }
                    if flock(file, LOCK_EX | LOCK_NB) == 0 { _exit(91) }
                    if errno != EWOULDBLOCK && errno != EAGAIN { _exit(92) }
                    _exit(0)
                }
                return child
            }
            try withExtendedLifetime(owner) {
                try #require(pid > 0)
                var status: CInt = 0
                #expect(waitpid(pid, &status, 0) == pid)
                #expect(status == 0)
                #expect(throws: AgentStateDirectoryInUse.self) { try AgentStateDirectoryLock(at: root) }
            }
        }
    }

    @Test("Process death releases ownership without deleting the lock file")
    func crashedOwner() throws {
        try fixture { root in
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            let file = open(root + "/.agent.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            try #require(file >= 0)
            let pid = fork()
            if pid == 0 {
                if flock(file, LOCK_EX | LOCK_NB) != 0 { _exit(90) }
                _ = kill(getpid(), SIGKILL)
                _exit(91)
            }
            _ = close(file)
            try #require(pid > 0)
            var status: CInt = 0
            #expect(waitpid(pid, &status, 0) == pid)
            #expect(status & 0x7f == SIGKILL)
            let successor = try AgentStateDirectoryLock(at: root)
            withExtendedLifetime(successor) {
                #expect(throws: AgentStateDirectoryInUse.self) { try AgentStateDirectoryLock(at: root) }
            }
        }
    }
    #endif
}
