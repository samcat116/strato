import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

private actor BlockDeviceLaunchRecorder {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeout: Duration?
        let environment: [String: String]?
        let maxOutputBytes: Int?
    }

    private var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private struct ExpectedProbeFailure: Error {}

private actor StorageObservationSequence {
    private var outcomes: [[ObservedStorageDevice]?]
    private var callCount = 0

    init(_ outcomes: [[ObservedStorageDevice]?]) {
        self.outcomes = outcomes
    }

    func next() -> [ObservedStorageDevice]? {
        callCount += 1
        return outcomes.isEmpty ? nil : outcomes.removeFirst()
    }

    func calls() -> Int {
        callCount
    }
}

private actor SuspendedStorageObservation {
    private var callCount = 0
    private var continuations: [CheckedContinuation<[ObservedStorageDevice]?, Never>] = []

    func observe() async -> [ObservedStorageDevice]? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        while callCount == 0 {
            await Task.yield()
        }
    }

    func calls() -> Int {
        callCount
    }

    func finish(with value: [ObservedStorageDevice]?) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}

@Suite("Block device inventory")
struct BlockDeviceInventoryTests {
    @Test("a blank whole disk is available and WWN identified")
    func decodesBlankDisk() throws {
        let devices = try decode(
            """
            {
              "blockdevices": [
                {
                  "name": "sdb", "path": "/dev/sdb", "type": "disk",
                  "size": 1000204886016, "model": " FastDisk 1TB ",
                  "serial": " SERIAL-1 ", "wwn": " 0x5000CCA123ABCDEF ",
                  "rota": false, "ro": false, "fstype": null, "pttype": null,
                  "mountpoints": [null], "state": "running", "children": null
                }
              ]
            }
            """)

        let device = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(device.identity == .init(kind: .wwn, value: "5000cca123abcdef"))
        #expect(device.devicePath == "/dev/sdb")
        #expect(device.sizeBytes == 1_000_204_886_016)
        #expect(device.model == "FastDisk 1TB")
        #expect(device.serial == "SERIAL-1")
        #expect(device.wwn == "0x5000CCA123ABCDEF")
        #expect(device.rotational == false)
        #expect(device.state == .available)
        #expect(device.uses == [])
    }

    @Test("descendant filesystem, mount, partition, and LVM facts occupy the whole disk")
    func derivesRecursiveUses() throws {
        let devices = try decode(
            """
            {
              "blockdevices": [
                {
                  "name": "sda", "path": "/dev/sda", "type": "disk",
                  "size": "2000398934016", "model": "Root Disk", "serial": "ROOT-1",
                  "wwn": null, "rota": 1, "ro": 0, "fstype": null, "pttype": "gpt",
                  "mountpoints": [null], "state": "running",
                  "children": [
                    {
                      "name": "sda1", "path": "/dev/sda1", "type": "part",
                      "size": "1999000000000", "model": null, "serial": null,
                      "wwn": null, "rota": "1", "ro": "0", "fstype": "LVM2_member",
                      "pttype": null, "mountpoints": [null], "state": null,
                      "children": [
                        {
                          "name": "vg-local", "path": "/dev/mapper/vg-local", "type": "lvm",
                          "size": 1998000000000, "model": null, "serial": null,
                          "wwn": null, "rota": true, "ro": false, "fstype": "ext4",
                          "pttype": null, "mountpoints": ["/var/lib/strato"], "state": null
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """)

        let device = try #require(devices.first)
        #expect(device.identity == .init(kind: .serial, value: "ROOT-1"))
        #expect(device.state == .inUse)
        #expect(
            device.uses == [
                .childDevice, .filesystem, .lvmPhysicalVolume, .mounted, .partitionTable,
            ])
    }

    @Test("swap and read-only evidence produce typed use reasons")
    func derivesSwapAndReadOnlyUses() throws {
        let devices = try decode(
            """
            {
              "blockdevices": [
                {
                  "name": "sdb", "path": "/dev/sdb", "type": "disk",
                  "size": 1000, "model": null, "serial": "SWAP", "wwn": null,
                  "rota": false, "ro": false, "fstype": null, "pttype": null,
                  "mountpoints": [null], "state": "running",
                  "children": [
                    {
                      "name": "sdb1", "path": "/dev/sdb1", "type": "part",
                      "size": 900, "model": null, "serial": null, "wwn": null,
                      "rota": false, "ro": false, "fstype": "swap", "pttype": null,
                      "mountpoints": ["[SWAP]"], "state": null
                    }
                  ]
                },
                {
                  "name": "sdc", "path": "/dev/sdc", "type": "disk",
                  "size": 2000, "model": null, "serial": null, "wwn": null,
                  "rota": false, "ro": true, "fstype": null, "pttype": null,
                  "mountpoints": null, "state": "running"
                }
              ]
            }
            """)

        #expect(devices[0].uses == [.childDevice, .mounted, .swap])
        #expect(devices[0].state == .inUse)
        #expect(devices[1].identity == nil)
        #expect(devices[1].uses == [.readOnly])
        #expect(devices[1].state == .inUse)
    }

    @Test("zero size and failed kernel states are faulted")
    func derivesFaultedState() throws {
        let devices = try decode(
            """
            {
              "blockdevices": [
                {
                  "name": "sdb", "path": "/dev/sdb", "type": "disk", "size": 0,
                  "model": null, "serial": "ZERO", "wwn": null, "rota": false,
                  "ro": false, "fstype": null, "pttype": null, "mountpoints": null,
                  "state": "running"
                },
                {
                  "name": "sdc", "path": "/dev/sdc", "type": "disk", "size": 100,
                  "model": null, "serial": "FAILED", "wwn": null, "rota": false,
                  "ro": false, "fstype": "ext4", "pttype": null, "mountpoints": null,
                  "state": "offline"
                }
              ]
            }
            """)

        #expect(devices[0].state == .faulted)
        #expect(devices[1].state == .faulted)
        #expect(devices[1].uses == [.filesystem])
    }

    @Test("non-disk top-level nodes never become selectable rows")
    func excludesNonDisks() throws {
        let devices = try decode(
            """
            {
              "blockdevices": [
                {"name":"loop0","path":"/dev/loop0","type":"loop","size":10,"rota":false,"ro":false},
                {"name":"sr0","path":"/dev/sr0","type":"rom","size":20,"rota":true,"ro":true}
              ]
            }
            """)

        #expect(devices.isEmpty)
    }

    @Test("a malformed document rejects the complete observation")
    func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try BlockDeviceInventoryProbe.decode(Data("not-json".utf8))
        }
    }

    @Test("a negative whole-disk size rejects the complete observation")
    func rejectsNegativeSize() {
        #expect(throws: (any Error).self) {
            try decode(
                """
                {"blockdevices":[{"name":"sdb","path":"/dev/sdb","type":"disk","size":-1,"rota":false,"ro":false}]}
                """)
        }
    }

    @Test("probe uses the first installed standard lsblk path with bounded arguments")
    func launchesBoundedLSBLKCommand() async throws {
        let recorder = BlockDeviceLaunchRecorder()
        let candidates = [
            URL(fileURLWithPath: "/missing/lsblk"),
            URL(fileURLWithPath: "/usr/bin/lsblk"),
            URL(fileURLWithPath: "/bin/lsblk"),
        ]
        let probe = BlockDeviceInventoryProbe(
            executableCandidates: candidates,
            fileExists: { $0 == "/usr/bin/lsblk" },
            run: { executableURL, arguments, timeout, environment, maxOutputBytes in
                await recorder.record(
                    .init(
                        executableURL: executableURL,
                        arguments: arguments,
                        timeout: timeout,
                        environment: environment,
                        maxOutputBytes: maxOutputBytes))
                return ProcessResult(
                    terminationStatus: 0,
                    standardOutput: Data(
                        """
                        {"blockdevices":[{"path":"/dev/sdb","type":"disk","size":100,"serial":"S1","rota":false,"ro":false}]}
                        """.utf8),
                    standardError: Data())
            })

        let devices = await probe.observeUsingCandidates()
        let call = try #require(await recorder.recordedCalls().first)

        #expect(devices?.map(\.devicePath) == ["/dev/sdb"])
        #expect(call.executableURL.path == "/usr/bin/lsblk")
        #expect(
            call.arguments == [
                "--json", "--bytes", "--tree", "--output",
                "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,ROTA,RO,FSTYPE,PTTYPE,MOUNTPOINTS,STATE",
            ])
        #expect(call.timeout == .seconds(5))
        #expect(call.maxOutputBytes == 4 * 1024 * 1024)
        #expect(call.environment?["LC_ALL"] == "C")
    }

    @Test("probe failures are no opinion, never authoritative emptiness")
    func failuresReturnNil() async {
        let noExecutable = BlockDeviceInventoryProbe(
            executableCandidates: [URL(fileURLWithPath: "/missing/lsblk")],
            fileExists: { _ in false },
            run: { _, _, _, _, _ in
                Issue.record("runner must not be called without an executable")
                return ProcessResult(
                    terminationStatus: 0, standardOutput: Data(), standardError: Data())
            })
        #expect(await noExecutable.observeUsingCandidates() == nil)

        let nonzero = probeReturning(
            ProcessResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data("permission denied".utf8)))
        #expect(await nonzero.observeUsingCandidates() == nil)

        let malformed = probeReturning(
            ProcessResult(
                terminationStatus: 0,
                standardOutput: Data("not-json".utf8),
                standardError: Data()))
        #expect(await malformed.observeUsingCandidates() == nil)

        let thrown = BlockDeviceInventoryProbe(
            executableCandidates: [URL(fileURLWithPath: "/usr/bin/lsblk")],
            fileExists: { _ in true },
            run: { _, _, _, _, _ in throw ExpectedProbeFailure() })
        #expect(await thrown.observeUsingCandidates() == nil)
    }

    #if !os(Linux)
    @Test("the public probe makes no disk claim on non-Linux hosts")
    func nonLinuxPublicProbeReturnsNil() async {
        let probe = probeReturning(
            ProcessResult(
                terminationStatus: 0,
                standardOutput: Data(
                    """
                    {"blockdevices":[{"path":"/dev/sdb","type":"disk","size":100,"serial":"S1","rota":false,"ro":false}]}
                    """.utf8),
                standardError: Data()))

        #expect(await probe.observe() == nil)
    }
    #endif

    @Test("cache distinguishes failure, empty success, and throttled reuse")
    func cachePublishesLatestCompletedOutcome() async {
        let device = fixtureDevice(path: "/dev/sdb")
        let sequence = StorageObservationSequence([[device], nil, []])
        let cache = StorageDeviceInventoryCache(
            minimumRefreshInterval: .seconds(30),
            observer: { await sequence.next() })
        let start = ContinuousClock.now

        #expect(await cache.snapshot() == nil)

        await cache.refresh(now: start)
        #expect(await cache.snapshot()?.map(\.devicePath) == ["/dev/sdb"])
        #expect(await sequence.calls() == 1)

        await cache.refresh(now: start + .seconds(10))
        #expect(await sequence.calls() == 1)
        #expect(await cache.snapshot()?.map(\.devicePath) == ["/dev/sdb"])

        await cache.refresh(now: start + .seconds(30))
        #expect(await sequence.calls() == 2)
        #expect(await cache.snapshot() == nil)

        await cache.refresh(now: start + .seconds(60))
        #expect(await sequence.calls() == 3)
        #expect(await cache.snapshot()?.isEmpty == true)
    }

    @Test("forced refresh bypasses the cadence gate")
    func cacheForceRefreshes() async {
        let sequence = StorageObservationSequence([
            [fixtureDevice(path: "/dev/sdb")],
            [fixtureDevice(path: "/dev/sdc")],
        ])
        let cache = StorageDeviceInventoryCache(
            minimumRefreshInterval: .seconds(30),
            observer: { await sequence.next() })
        let start = ContinuousClock.now

        await cache.refresh(now: start)
        await cache.refresh(force: true, now: start + .seconds(1))

        #expect(await sequence.calls() == 2)
        #expect(await cache.snapshot()?.map(\.devicePath) == ["/dev/sdc"])
    }

    @Test("concurrent forced refreshes share one observation")
    func cacheCoalescesConcurrentRefreshes() async {
        let suspended = SuspendedStorageObservation()
        let cache = StorageDeviceInventoryCache(
            observer: { await suspended.observe() })
        let now = ContinuousClock.now

        let first = Task { await cache.refresh(force: true, now: now) }
        await suspended.waitUntilStarted()
        let second = Task { await cache.refresh(force: true, now: now) }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(await suspended.calls() == 1)
        await suspended.finish(with: [fixtureDevice(path: "/dev/sdb")])
        await first.value
        await second.value
        #expect(await cache.snapshot()?.map(\.devicePath) == ["/dev/sdb"])
    }

    private func decode(_ json: String) throws -> [ObservedStorageDevice] {
        try BlockDeviceInventoryProbe.decode(Data(json.utf8))
    }

    private func probeReturning(_ result: ProcessResult) -> BlockDeviceInventoryProbe {
        BlockDeviceInventoryProbe(
            executableCandidates: [URL(fileURLWithPath: "/usr/bin/lsblk")],
            fileExists: { _ in true },
            run: { _, _, _, _, _ in result })
    }

    private func fixtureDevice(path: String) -> ObservedStorageDevice {
        ObservedStorageDevice(
            identity: .init(kind: .serial, value: "SERIAL"),
            devicePath: path,
            sizeBytes: 100,
            serial: "SERIAL",
            rotational: false,
            state: .available,
            uses: [])
    }
}
