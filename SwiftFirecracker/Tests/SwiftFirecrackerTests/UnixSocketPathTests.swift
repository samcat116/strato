import Foundation
import Testing

@testable import SwiftFirecracker

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Unix socket path length handling")
struct UnixSocketPathTests {

    /// Builds a directory whose absolute path exceeds any sun_path buffer and
    /// returns a socket path inside it.
    private func makeLongSocketPath() throws -> (base: URL, socketPath: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sunpath-\(UUID().uuidString)")
        var dir = base
        while dir.path.utf8.count < 150 {
            dir.appendPathComponent("dddddddddd")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (base, dir.appendingPathComponent("firecracker.socket").path)
    }

    @Test("short paths pass through untouched")
    func shortPathPassesThrough() throws {
        let connectable = try UnixSocketPath.connectable(path: "/tmp/x.sock", capacity: 104)
        #expect(connectable.path == "/tmp/x.sock")
        #expect(connectable.dirFD == nil)
    }

    #if os(Linux)
    @Test("overlong paths connect through a /proc/self/fd alias resolving to the same file")
    func longPathUsesProcAlias() throws {
        let (base, socketPath) = try makeLongSocketPath()
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular file stands in for the socket: the alias mechanism is
        // path resolution, not socket semantics.
        FileManager.default.createFile(atPath: socketPath, contents: Data("marker".utf8))

        let connectable = try UnixSocketPath.connectable(path: socketPath, capacity: 108)
        defer { connectable.closeDirFD() }

        #expect(connectable.path.hasPrefix("/proc/self/fd/"))
        #expect(connectable.path.utf8.count < 108)
        #expect(connectable.dirFD != nil)
        // The alias resolves to the very file at the overlong path.
        let resolved = FileManager.default.contents(atPath: connectable.path)
        #expect(resolved == Data("marker".utf8))
    }
    #else
    @Test("overlong paths are rejected off Linux (jailed layouts do not exist there)")
    func longPathRejectedOffLinux() throws {
        let (base, socketPath) = try makeLongSocketPath()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(throws: FirecrackerError.self) {
            _ = try UnixSocketPath.connectable(path: socketPath, capacity: 104)
        }
    }
    #endif
}
