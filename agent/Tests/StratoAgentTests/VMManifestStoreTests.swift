import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Test-only readers for the load result. Deliberately not on the production
/// type: an `entries`-that-defaults-to-empty accessor is exactly the collapse
/// STR-138 removed, and callers must keep being made to handle `.unreadable`.
extension ManifestLoad {
    fileprivate var loadedEntries: [String: VMManifestEntry] {
        guard case .loaded(let entries, _) = self else { return [:] }
        return entries
    }

    fileprivate var loadedQuarantined: [String: QuarantinedManifestEntry] {
        guard case .loaded(_, let quarantined) = self else { return [:] }
        return quarantined
    }

    fileprivate var readFailure: ManifestReadFailure? {
        guard case .unreadable(let failure) = self else { return nil }
        return failure
    }

    fileprivate var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

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

        let loaded = store.load().loadedEntries
        #expect(loaded.count == 2)
        #expect(loaded["vm-a"]?.hypervisorType == .qemu)
        #expect(loaded["vm-a"]?.spec.cpus == 2)
        #expect(loaded["vm-b"]?.hypervisorType == .firecracker)
        #expect(loaded["vm-b"]?.spec.cpus == 4)
        #expect(loaded["vm-b"]?.spec.memoryBytes == 1_073_741_824)
    }

    @Test("Disk reservations survive the manifest round-trip")
    func diskReservationRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let spec = VMSpec(
            cpus: 2, memoryBytes: 1_073_741_824, diskBytes: 21_474_836_480, boot: .disk(firmware: nil))
        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: spec)])

        let loaded = store.load().loadedEntries
        #expect(loaded["vm-a"]?.spec.diskBytes == 21_474_836_480)
        #expect(loaded.values.totalReservedDiskBytes == 21_474_836_480)
    }

    @Test("Reserved-disk total treats missing diskBytes and sandbox entries as zero")
    func totalReservedDiskTreatsMissingAsZero() {
        let withDisk = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, diskBytes: 5_368_709_120, boot: .disk(firmware: nil))
        let entries: [String: VMManifestEntry] = [
            "vm-new": VMManifestEntry(hypervisorType: .qemu, spec: withDisk),
            // A spec persisted before diskBytes existed (issue #473).
            "vm-old": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
            // Sandboxes reserve no disk, matching the scheduler.
            "sb-a": VMManifestEntry(
                sandboxSpec: SandboxSpec(image: "ghcr.io/acme/worker:v3", cpus: 1, memoryBytes: 268_435_456)),
        ]
        #expect(entries.values.totalReservedDiskBytes == 5_368_709_120)
    }

    @Test("A host with no manifest at all reads as fresh, not as a failed read")
    func freshWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // The first-boot path, and the one case that may be read as "nothing
        // is running here": no manifest, no legacy manifest, nothing to
        // salvage. It must stay distinguishable from an unreadable file.
        let load = makeStore(dir: dir).load()
        #expect(load.isFresh)
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
    }

    @Test("An empty manifest object still reads as an empty host")
    func emptyObjectLoadsAsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("{}".utf8).write(to: URL(fileURLWithPath: store.path))
        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
        #expect(!load.isFresh)
    }

    @Test("Legacy QEMU manifest (VMSpec map) migrates as QEMU entries and is removed")
    func migratesLegacySpecManifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacyPath = dir + "/qemu-manifest.json"

        let legacy = ["vm-legacy": makeSpec(cpus: 3, memoryBytes: 512_000_000)]
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: legacyPath))

        let store = makeStore(dir: dir)
        let loaded = store.load().loadedEntries
        #expect(loaded.count == 1)
        #expect(loaded["vm-legacy"]?.hypervisorType == .qemu)
        #expect(loaded["vm-legacy"]?.spec.cpus == 3)
        #expect(loaded["vm-legacy"]?.spec.memoryBytes == 512_000_000)

        // The migration is persisted in the unified format and the legacy file removed,
        // so a second load (e.g. after another restart) sees the same entries.
        #expect(!FileManager.default.fileExists(atPath: legacyPath))
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(store.load().loadedEntries["vm-legacy"]?.hypervisorType == .qemu)
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

        let loaded = makeStore(dir: dir).load().loadedEntries
        #expect(loaded["vm-old"]?.hypervisorType == .qemu)
        #expect(loaded["vm-old"]?.spec.cpus == 6)
        #expect(loaded["vm-old"]?.spec.maxCpus == 8)
        #expect(loaded["vm-old"]?.spec.memoryBytes == 4_294_967_296)
        #expect(!FileManager.default.fileExists(atPath: legacyPath))
    }

    @Test("An unreadable legacy manifest is not an empty host either")
    func unreadableLegacyManifestIsNotEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacyPath = dir + "/qemu-manifest.json"
        try Data("{\"vm-a\": ".utf8).write(to: URL(fileURLWithPath: legacyPath))

        let load = makeStore(dir: dir).load()
        #expect(load.readFailure?.path == legacyPath)
        #expect(!load.isFresh)
        // Nothing writes to the legacy path, so the evidence stays put.
        #expect(FileManager.default.fileExists(atPath: legacyPath))
    }

    @Test("Unified manifest wins over a lingering legacy file")
    func unifiedManifestWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save(["vm-new": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec())])
        let legacy = ["vm-stale": makeSpec()]
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: dir + "/qemu-manifest.json"))

        let loaded = store.load().loadedEntries
        #expect(loaded.count == 1)
        #expect(loaded["vm-new"]?.hypervisorType == .firecracker)
    }

    @Test("Legacy manifest survives when the unified rewrite fails")
    func legacySurvivesFailedRewrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacyPath = dir + "/qemu-manifest.json"
        try JSONEncoder().encode(["vm-a": makeSpec()]).write(to: URL(fileURLWithPath: legacyPath))

        // A regular file where the unified manifest's parent directory should be
        // makes createDirectory (and therefore save) fail.
        let blocker = dir + "/blocker"
        FileManager.default.createFile(atPath: blocker, contents: Data())
        let store = VMManifestStore(
            path: blocker + "/vm-manifest.json",
            legacyQEMUManifestPath: legacyPath,
            logger: Logger(label: "test")
        )

        // The entries are still returned for this process's orphan tracking, and
        // the legacy file is retained so the next start can retry the migration.
        let loaded = store.load().loadedEntries
        #expect(loaded["vm-a"]?.hypervisorType == .qemu)
        #expect(FileManager.default.fileExists(atPath: legacyPath))
        #expect(store.load().loadedEntries["vm-a"]?.hypervisorType == .qemu)
    }

    // MARK: - Unreadable manifests (STR-138)

    @Test("A manifest that is not JSON reads as unreadable, never as an empty host")
    func corruptManifestIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("not json".utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure?.path == store.path)
        #expect(!load.isFresh)
        #expect(load.loadedEntries.isEmpty)
    }

    @Test("A truncated manifest reads as unreadable")
    func truncatedManifestIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
            "vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
        ])
        // What a host that lost power mid-write, or filled its filesystem,
        // leaves behind.
        let whole = try Data(contentsOf: URL(fileURLWithPath: store.path))
        try whole.prefix(whole.count / 2).write(to: URL(fileURLWithPath: store.path))

        #expect(store.load().readFailure != nil)
    }

    @Test("A zero-length manifest reads as unreadable")
    func emptyFileIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data().write(to: URL(fileURLWithPath: store.path))
        #expect(store.load().readFailure != nil)
    }

    @Test("An unreadable manifest is preserved byte-for-byte and left in place")
    func unreadableManifestIsPreserved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let original = Data("{\"vm-a\": {\"hypervisorType\"".utf8)
        try original.write(to: URL(fileURLWithPath: store.path))

        let failure = try #require(store.load().readFailure)
        let preservedPath = try #require(failure.preservedCopyPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: preservedPath)) == original)
        // A copy, not a move: the original is what a build that understands
        // the file needs to find, and moving it aside would make the next
        // start read the host as fresh.
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == original)
    }

    @Test("A crash-looping agent leaves one preserved copy, not one per restart")
    func preservationIsDedupedByContent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("garbage".utf8).write(to: URL(fileURLWithPath: store.path))
        let first = try #require(store.load().readFailure?.preservedCopyPath)
        let second = try #require(store.load().readFailure?.preservedCopyPath)
        #expect(first == second)

        let copies = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.contains(VMManifestStore.preservedSuffix) }
        #expect(copies.count == 1)
    }

    // MARK: - Quarantined entries (STR-138)

    @Test("One entry this build cannot route costs one entry, not the host")
    func unknownHypervisorTypeQuarantinesOneEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        // The rollback scenario: an agent downgraded past a hypervisor backend
        // it once wrote here. The whole dictionary used to decode as a unit, so
        // this single entry discarded every QEMU and Firecracker VM with it.
        let futureSpec = VMSpec(
            cpus: 8, memoryBytes: 8_589_934_592, diskBytes: 10_737_418_240, boot: .disk(firmware: nil))
        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2)),
            "vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 4)),
            "vm-c": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec(cpus: 1)),
            "vm-future": VMManifestEntry(hypervisorType: .qemu, spec: futureSpec),
        ])
        // Rewrite one entry's backend to a case this build has never heard of,
        // leaving everything else exactly as the newer agent wrote it.
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var future = try #require(raw["vm-future"] as? [String: Any])
        future["hypervisorType"] = "libvirt"
        raw["vm-future"] = future
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.count == 3)
        #expect(load.loadedEntries["vm-a"]?.spec.cpus == 2)
        #expect(load.loadedEntries["vm-c"]?.hypervisorType == .firecracker)

        let quarantined = try #require(load.loadedQuarantined["vm-future"])
        #expect(load.loadedQuarantined.count == 1)
        #expect(quarantined.hypervisorTypeRawValue == "libvirt")
        #expect(quarantined.reason.contains("libvirt"))
        // The safety-critical half: the entry still reserves what it is using,
        // so the scheduler cannot hand that capacity to a new placement.
        #expect(quarantined.cpus == 8)
        #expect(quarantined.memoryBytes == 8_589_934_592)
        #expect(quarantined.diskBytes == 10_737_418_240)
        #expect(quarantined.effectiveKind == .vm)
    }

    @Test("An entry whose spec this build cannot decode is quarantined, not dropped")
    func undecodableSpecQuarantinesOneEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        // A required VMSpec field that isn't there — what rolling back past a
        // spec change looks like on disk.
        let json = """
            {
              "vm-a": {"kind": "vm", "hypervisorType": "qemu", "spec": {"cpus": 3, "memoryBytes": 1024}},
              "sb-a": {"kind": "sandbox", "hypervisorType": "firecracker", "spec": "not-an-object",
                       "sandboxSpec": {"cpus": 2, "memoryBytes": 2048}}
            }
            """
        try Data(json.utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
        #expect(load.loadedQuarantined.count == 2)
        #expect(load.loadedQuarantined["vm-a"]?.cpus == 3)
        #expect(load.loadedQuarantined["vm-a"]?.memoryBytes == 1024)
        // Sandbox entries salvage their reservation from `sandboxSpec` when
        // the projected `spec` is the unreadable part.
        #expect(load.loadedQuarantined["sb-a"]?.effectiveKind == .sandbox)
        #expect(load.loadedQuarantined["sb-a"]?.cpus == 2)
        #expect(load.loadedQuarantined["sb-a"]?.memoryBytes == 2048)
    }

    @Test("An entry that is not an object at all is still quarantined")
    func nonObjectEntryIsQuarantined() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("{\"vm-a\": 7}".utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        // Nothing can be salvaged but the id — which is still enough to refuse
        // to create a second copy of whatever is running under it.
        let quarantined = try #require(load.loadedQuarantined["vm-a"])
        #expect(quarantined.cpus == 0)
        #expect(quarantined.kind == nil)
        #expect(quarantined.effectiveKind == .vm)
    }

    @Test("Saving re-emits quarantined entries verbatim, so rolling forward restores them")
    func savePreservesQuarantinedEntriesVerbatim() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let json = """
            {"vm-future": {"kind": "vm", "hypervisorType": "libvirt",
                           "spec": {"cpus": 4, "memoryBytes": 4096}, "domainXML": "<domain/>"}}
            """
        try Data(json.utf8).write(to: URL(fileURLWithPath: store.path))

        let quarantined = store.load().loadedQuarantined
        #expect(quarantined.count == 1)

        // The agent creates a VM it *can* route; the write must not drop the
        // entry it cannot, nor rewrite it into a shape this build prefers —
        // the newer build needs the original routing field back.
        store.save(
            ["vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec())],
            preserving: quarantined)

        let written = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        let future = try #require(written["vm-future"] as? [String: Any])
        #expect(future["hypervisorType"] as? String == "libvirt")
        #expect(future["domainXML"] as? String == "<domain/>")
        #expect(written["vm-b"] != nil)

        // And it still quarantines the same way on the next read.
        let reloaded = store.load()
        #expect(reloaded.loadedEntries.keys.sorted() == ["vm-b"])
        #expect(reloaded.loadedQuarantined["vm-future"]?.hypervisorTypeRawValue == "libvirt")
    }

    @Test("Sandbox entries round-trip with their kind, spec, and synthesized reservation")
    func sandboxEntryRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let sandboxSpec = SandboxSpec(
            image: "ghcr.io/acme/worker:v3", imageDigest: "sha256:abc", cpus: 3, memoryBytes: 536_870_912)
        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2)),
            "sb-a": VMManifestEntry(sandboxSpec: sandboxSpec),
        ])

        let loaded = store.load().loadedEntries
        #expect(loaded.count == 2)
        #expect(loaded["vm-a"]?.kind == .vm)
        #expect(loaded["vm-a"]?.sandboxSpec == nil)
        #expect(loaded["sb-a"]?.kind == .sandbox)
        #expect(loaded["sb-a"]?.hypervisorType == .firecracker)
        #expect(loaded["sb-a"]?.sandboxSpec?.image == "ghcr.io/acme/worker:v3")
        #expect(loaded["sb-a"]?.sandboxSpec?.imageDigest == "sha256:abc")
        // The reservation projection is what restart-survival capacity
        // accounting reads, for both kinds.
        #expect(loaded["sb-a"]?.spec.cpus == 3)
        #expect(loaded["sb-a"]?.spec.memoryBytes == 536_870_912)
    }

    @Test("Manifest entries without a kind (pre-sandbox agents) decode as VMs")
    func kindlessEntryDecodesAsVM() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        // Exactly what a pre-#417 agent persisted: hypervisorType + spec only.
        struct LegacyEntry: Encodable {
            let hypervisorType: HypervisorType
            let spec: VMSpec
        }
        let legacy = ["vm-old": LegacyEntry(hypervisorType: .firecracker, spec: makeSpec(cpus: 5))]
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: store.path))

        let loaded = store.load().loadedEntries
        #expect(loaded["vm-old"]?.kind == .vm)
        #expect(loaded["vm-old"]?.hypervisorType == .firecracker)
        #expect(loaded["vm-old"]?.spec.cpus == 5)
        #expect(loaded["vm-old"]?.sandboxSpec == nil)
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
        #expect(store.load().loadedEntries["vm-a"]?.spec.cpus == 2)
    }
}
