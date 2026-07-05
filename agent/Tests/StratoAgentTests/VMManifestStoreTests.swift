import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("VMManifestStore Tests")
struct VMManifestStoreTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "vm-manifest-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(dir: String) -> VMManifestStore {
        VMManifestStore(
            path: dir + "/vm-manifest.json",
            legacyQEMUManifestPath: dir + "/qemu-manifest.json",
            logger: Logger(label: "test")
        )
    }

    private func makeSpec(cpus: Int = 2, memoryBytes: Int64 = 2_147_483_648) -> VMSpec {
        VMSpec(cpus: cpus, memoryBytes: memoryBytes, boot: .disk(firmware: nil))
    }

    @Test("Save and load round-trips entries with their hypervisor types")
    func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2)),
            "vm-b": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec(cpus: 4, memoryBytes: 1_073_741_824)),
        ])

        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded["vm-a"]?.hypervisorType == .qemu)
        #expect(loaded["vm-a"]?.spec.cpus == 2)
        #expect(loaded["vm-b"]?.hypervisorType == .firecracker)
        #expect(loaded["vm-b"]?.spec.cpus == 4)
        #expect(loaded["vm-b"]?.spec.memoryBytes == 1_073_741_824)
    }

    @Test("Load returns empty when no manifest exists")
    func emptyWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(makeStore(dir: dir).load().isEmpty)
    }

    @Test("Legacy QEMU manifest (VMSpec map) migrates as QEMU entries and is removed")
    func migratesLegacySpecManifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacyPath = dir + "/qemu-manifest.json"

        let legacy = ["vm-legacy": makeSpec(cpus: 3, memoryBytes: 512_000_000)]
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: legacyPath))

        let store = makeStore(dir: dir)
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded["vm-legacy"]?.hypervisorType == .qemu)
        #expect(loaded["vm-legacy"]?.spec.cpus == 3)
        #expect(loaded["vm-legacy"]?.spec.memoryBytes == 512_000_000)

        // The migration is persisted in the unified format and the legacy file removed,
        // so a second load (e.g. after another restart) sees the same entries.
        #expect(!FileManager.default.fileExists(atPath: legacyPath))
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(store.load()["vm-legacy"]?.hypervisorType == .qemu)
    }

    @Test("Pre-VMSpec legacy manifest (VmConfig) salvages resource reservations")
    func migratesPreVMSpecManifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacyPath = dir + "/qemu-manifest.json"

        let legacyJSON = """
            {"vm-old": {"cpus": {"boot_vcpus": 6, "max_vcpus": 8}, "memory": {"size": 4294967296}}}
            """
        try Data(legacyJSON.utf8).write(to: URL(fileURLWithPath: legacyPath))

        let loaded = makeStore(dir: dir).load()
        #expect(loaded["vm-old"]?.hypervisorType == .qemu)
        #expect(loaded["vm-old"]?.spec.cpus == 6)
        #expect(loaded["vm-old"]?.spec.maxCpus == 8)
        #expect(loaded["vm-old"]?.spec.memoryBytes == 4_294_967_296)
        #expect(!FileManager.default.fileExists(atPath: legacyPath))
    }

    @Test("Unified manifest wins over a lingering legacy file")
    func unifiedManifestWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save(["vm-new": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec())])
        let legacy = ["vm-stale": makeSpec()]
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: dir + "/qemu-manifest.json"))

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded["vm-new"]?.hypervisorType == .firecracker)
    }

    @Test("Corrupt manifest degrades to empty instead of crashing")
    func corruptManifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("not json".utf8).write(to: URL(fileURLWithPath: store.path))
        #expect(store.load().isEmpty)
    }

    @Test("Save creates intermediate directories")
    func savesIntoMissingDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = VMManifestStore(
            path: dir + "/nested/deeper/vm-manifest.json",
            logger: Logger(label: "test")
        )

        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec())])
        #expect(store.load()["vm-a"]?.spec.cpus == 2)
    }
}
