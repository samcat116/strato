import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("Disk Cache LRU")
struct DiskCacheLRUTests {

    private let logger = Logger(label: "test")

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "disk-cache-lru-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates an entry directory holding one file of `sizeBytes`, backdated
    /// to `age` seconds ago.
    private func makeEntry(root: String, name: String, sizeBytes: Int, age: TimeInterval) throws -> String {
        let dir = root + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: sizeBytes).write(to: URL(fileURLWithPath: dir + "/blob"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: dir)
        return dir
    }

    // MARK: - Victim selection (pure)

    private func entry(_ path: String, size: Int64, age: TimeInterval) -> DiskCacheLRU.Entry {
        DiskCacheLRU.Entry(path: path, sizeBytes: size, lastUsed: Date(timeIntervalSinceNow: -age))
    }

    @Test("nothing is selected while the cache fits the budget")
    func underBudget() {
        let entries = [entry("/a", size: 40, age: 100), entry("/b", size: 40, age: 200)]
        let victims = DiskCacheLRU.victims(entries: entries, budgetBytes: 100)
        #expect(victims.isEmpty)
    }

    @Test("oldest entries are selected first, and only until the cache fits")
    func lruOrder() {
        let entries = [
            entry("/newest", size: 40, age: 10),
            entry("/oldest", size: 40, age: 300),
            entry("/middle", size: 40, age: 100),
        ]
        let victims = DiskCacheLRU.victims(entries: entries, budgetBytes: 80)
        #expect(victims.map(\.path) == ["/oldest"])
    }

    @Test("incoming bytes shrink the effective budget")
    func incomingBytes() {
        let entries = [
            entry("/oldest", size: 40, age: 300),
            entry("/middle", size: 40, age: 100),
            entry("/newest", size: 40, age: 10),
        ]
        // 120 cached + 80 incoming vs budget 140 (target 60): two must go.
        let victims = DiskCacheLRU.victims(entries: entries, budgetBytes: 140, incomingBytes: 80)
        #expect(victims.map(\.path) == ["/oldest", "/middle"])
    }

    @Test("recently used entries are protected even over budget")
    func graceProtection() {
        let entries = [
            entry("/old", size: 40, age: 3600),
            entry("/recent", size: 40, age: 60),
        ]
        let victims = DiskCacheLRU.victims(
            entries: entries, budgetBytes: 10,
            protectedAfter: Date(timeIntervalSinceNow: -600))
        #expect(victims.map(\.path) == ["/old"])
    }

    // MARK: - Measurement and sweeping (on disk)

    @Test("measure sums file sizes recursively and reads directory mtime")
    func measureEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = try makeEntry(root: root, name: "entry", sizeBytes: 1000, age: 500)
        try FileManager.default.createDirectory(atPath: dir + "/nested", withIntermediateDirectories: true)
        try Data(repeating: 0, count: 500).write(to: URL(fileURLWithPath: dir + "/nested/blob2"))

        let measured = DiskCacheLRU.measure(entryDirectories: [dir, root + "/missing"])
        #expect(measured.count == 1)
        #expect(measured.first?.sizeBytes == 1500)
    }

    @Test("sweep deletes LRU entries until the cache fits")
    func sweepDeletes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let oldest = try makeEntry(root: root, name: "oldest", sizeBytes: 1000, age: 7200)
        let middle = try makeEntry(root: root, name: "middle", sizeBytes: 1000, age: 3600)
        let newest = try makeEntry(root: root, name: "newest", sizeBytes: 1000, age: 2400)

        let result = DiskCacheLRU.sweep(
            entryDirectories: [oldest, middle, newest],
            budgetBytes: 1500,
            logger: logger
        )

        #expect(!FileManager.default.fileExists(atPath: oldest))
        #expect(!FileManager.default.fileExists(atPath: middle))
        #expect(FileManager.default.fileExists(atPath: newest))
        #expect(result.freedBytes == 2000)
        #expect(result.remainingBytes == 1000)
        #expect(!result.stillOverBudget)
    }

    @Test("sweep reports over-budget when grace protects everything")
    func sweepGraceOverBudget() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fresh = try makeEntry(root: root, name: "fresh", sizeBytes: 1000, age: 0)

        let result = DiskCacheLRU.sweep(
            entryDirectories: [fresh],
            budgetBytes: 100,
            logger: logger
        )

        #expect(FileManager.default.fileExists(atPath: fresh))
        #expect(result.evicted.isEmpty)
        #expect(result.stillOverBudget)
    }

    @Test("touch refreshes an entry's LRU position")
    func touchRefreshes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let touched = try makeEntry(root: root, name: "touched", sizeBytes: 1000, age: 7200)
        let other = try makeEntry(root: root, name: "other", sizeBytes: 1000, age: 3600)

        DiskCacheLRU.touch(entryDirectory: touched)
        DiskCacheLRU.sweep(
            entryDirectories: [touched, other],
            budgetBytes: 1500,
            logger: logger
        )

        #expect(FileManager.default.fileExists(atPath: touched))
        #expect(!FileManager.default.fileExists(atPath: other))
    }
}
