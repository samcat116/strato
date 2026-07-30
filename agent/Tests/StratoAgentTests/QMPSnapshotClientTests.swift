import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Behavioral coverage for `QMPProbeClient`'s full-VM checkpoint commands
/// (issue #564) against the same in-memory fake monitor the balloon probes use:
/// block-node discovery, the snapshot job lifecycle (start → poll → dismiss),
/// failure verdicts, and job rejoining — all without a real socket.
@Suite("QMP snapshot commands")
struct QMPSnapshotClientTests {
    typealias Reply = QMPProbeClientTests.Reply
    typealias FakeQMPTransport = QMPProbeClientTests.FakeQMPTransport

    private static let emptyReturn = Array(#"{"return": {}}"#.utf8)

    private static func client(_ transport: FakeQMPTransport) -> QMPProbeClient {
        QMPProbeClient(transport: transport, logger: Logger(label: "test.qmp.snapshot"))
    }

    /// A `query-block` reply: a qcow2 boot disk, a qcow2 data disk, a raw
    /// read-only seed ISO, and a writable raw pflash variable store — the
    /// shape a UEFI VM with a cloud-init seed actually presents.
    private static func queryBlockReply(snapshotTag: String? = nil, vmStateSize: Int64 = 2_147_483_648)
        -> [UInt8]
    {
        let bootSnapshots =
            snapshotTag.map {
                #"[{"id": "1", "name": "\#($0)", "vm-state-size": \#(vmStateSize)}]"#
            } ?? "[]"
        let dataSnapshots =
            snapshotTag.map { #"[{"id": "1", "name": "\#($0)", "vm-state-size": 0}]"# } ?? "[]"
        let body = """
            {"return": [
              {"device": "drive0", "inserted": {"node-name": "#block100", "drv": "qcow2",
                "file": "/vms/vm-1/disk.qcow2", "ro": false,
                "image": {"snapshots": \(bootSnapshots)}}},
              {"device": "drive1", "inserted": {"node-name": "#block200", "drv": "qcow2",
                "file": "/vms/vm-1/data.qcow2", "ro": false,
                "image": {"snapshots": \(dataSnapshots)}}},
              {"device": "drive2", "inserted": {"node-name": "#block300", "drv": "raw",
                "file": "/vms/vm-1/seed.iso", "ro": true, "image": {"snapshots": []}}},
              {"device": "pflash1", "inserted": {"node-name": "#block400", "drv": "raw",
                "file": "/vms/vm-1/nvram.fd", "ro": false, "image": {"snapshots": []}}}
            ]}
            """
        return Array(body.utf8)
    }

    /// A `query-jobs` reply that reports the job as running for the first
    /// `runningPolls` queries and concluded thereafter.
    private final class JobScript: @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        let jobId: String
        let runningPolls: Int
        let error: String?

        init(jobId: String, runningPolls: Int = 1, error: String? = nil) {
            self.jobId = jobId
            self.runningPolls = runningPolls
            self.error = error
        }

        func next() -> [UInt8] {
            let status: String = lock.withLock {
                polls += 1
                return polls <= runningPolls ? "running" : "concluded"
            }
            var entry = #"{"id": "\#(jobId)", "status": "\#(status)""#
            if status == "concluded", let error {
                entry += #", "error": "\#(error)""#
            }
            entry += "}"
            return Array(#"{"return": [\#(entry)]}"#.utf8)
        }
    }

    /// A handler for a healthy checkpoint flow.
    private static func handler(
        job: JobScript,
        queryBlock: @escaping @Sendable () -> [UInt8],
        // `query-jobs` is asked once before the command is issued (the rejoin
        // check); by default that first answer reports no job at all.
        jobExistsUpFront: Bool = false
    ) -> @Sendable (String) -> Reply {
        let asked = ManagedAtomicFlag()
        return { execute in
            switch execute {
            case "qmp_capabilities":
                return .object(emptyReturn)
            case "query-block":
                return .object(queryBlock())
            case "query-jobs":
                if !jobExistsUpFront, asked.setIfUnset() {
                    return .object(Array(#"{"return": []}"#.utf8))
                }
                return .object(job.next())
            case "snapshot-save", "snapshot-load", "snapshot-delete", "job-dismiss":
                return .object(emptyReturn)
            case "query-version":
                return .object(
                    Array(#"{"return": {"qemu": {"major": 9, "minor": 1, "micro": 0}}}"#.utf8))
            default:
                return .object(
                    Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
            }
        }
    }

    private final class ManagedAtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var unset = true
        /// True exactly once, on the first call.
        func setIfUnset() -> Bool {
            lock.withLock {
                defer { unset = false }
                return unset
            }
        }
    }

    // MARK: - Block topology

    @Test("query-block maps to nodes that say which can hold a checkpoint")
    func blockNodesMapped() async throws {
        let transport = FakeQMPTransport(
            handler: Self.handler(job: JobScript(jobId: "unused"), queryBlock: { Self.queryBlockReply() }))
        let nodes = try await Self.client(transport).blockNodes()

        #expect(nodes.map(\.nodeName) == ["#block100", "#block200", "#block300", "#block400"])
        #expect(nodes.map(\.supportsInternalSnapshots) == [true, true, false, false])
        // The read-only seed and the writable raw variable store are the two
        // reasons a real VM's node list is not simply "all qcow2".
        #expect(nodes[2].readonly)
        #expect(!nodes[3].readonly)
        #expect(nodes[3].filename == "/vms/vm-1/nvram.fd")
    }

    // MARK: - Save

    @Test("save issues the job, polls to conclusion, dismisses, and reports the size")
    func saveHappyPath() async throws {
        let job = JobScript(jobId: "strato-save-abc", runningPolls: 2)
        let tag = "strato-abc"
        let transport = FakeQMPTransport(
            handler: Self.handler(job: job, queryBlock: { Self.queryBlockReply(snapshotTag: tag) }))

        let size = try await Self.client(transport).saveSnapshot(
            tag: tag, vmstateNode: "#block100", devices: ["#block100", "#block200"],
            jobId: "strato-save-abc", pollInterval: .milliseconds(1))

        // The vmstate size comes from the node that actually holds machine
        // state, not from the disk-only half of the checkpoint.
        #expect(size == 2_147_483_648)

        let save = try #require(transport.requests.first { $0["execute"] as? String == "snapshot-save" })
        let arguments = try #require(save["arguments"] as? [String: Any])
        #expect(arguments["job-id"] as? String == "strato-save-abc")
        #expect(arguments["tag"] as? String == tag)
        #expect(arguments["vmstate"] as? String == "#block100")
        #expect(arguments["devices"] as? [String] == ["#block100", "#block200"])

        // Manual-dismiss jobs linger until reaped; leaving one behind would
        // collide with the next checkpoint's job id.
        #expect(transport.executes.contains("job-dismiss"))
    }

    @Test("a concluded job carrying an error fails the checkpoint")
    func saveReportsJobError() async throws {
        let job = JobScript(jobId: "strato-save-abc", runningPolls: 0, error: "No space left on device")
        let transport = FakeQMPTransport(
            handler: Self.handler(job: job, queryBlock: { Self.queryBlockReply() }))

        await #expect(throws: QMPProbeClient.QMPProbeError.self) {
            try await Self.client(transport).saveSnapshot(
                tag: "strato-abc", vmstateNode: "#block100", devices: ["#block100"],
                jobId: "strato-save-abc", pollInterval: .milliseconds(1))
        }
        // The verdict is collected even on failure, so a retry can reuse the id.
        #expect(transport.executes.contains("job-dismiss"))
    }

    @Test("a job that is already running is rejoined, not started again")
    func saveRejoinsLiveJob() async throws {
        let job = JobScript(jobId: "strato-save-abc", runningPolls: 1)
        let transport = FakeQMPTransport(
            handler: Self.handler(
                job: job, queryBlock: { Self.queryBlockReply(snapshotTag: "strato-abc") },
                jobExistsUpFront: true))

        _ = try await Self.client(transport).saveSnapshot(
            tag: "strato-abc", vmstateNode: "#block100", devices: ["#block100"],
            jobId: "strato-save-abc", pollInterval: .milliseconds(1))

        // A replayed request must not run a second save against the same
        // disks; it waits on the one already in flight.
        #expect(!transport.executes.contains("snapshot-save"))
        #expect(transport.executes.contains("job-dismiss"))
    }

    @Test("a job that vanishes before concluding is an error, not a success")
    func saveFailsOnVanishedJob() async throws {
        // `query-jobs` always answers empty: the up-front check sees no job
        // (so the save is issued) and every poll after it sees none either.
        let transport = FakeQMPTransport { execute in
            switch execute {
            case "qmp_capabilities", "snapshot-save", "job-dismiss":
                return .object(Self.emptyReturn)
            case "query-jobs":
                return .object(Array(#"{"return": []}"#.utf8))
            default:
                return .object(Array(#"{"return": []}"#.utf8))
            }
        }

        await #expect(throws: QMPProbeClient.QMPProbeError.self) {
            try await Self.client(transport).saveSnapshot(
                tag: "strato-abc", vmstateNode: "#block100", devices: ["#block100"],
                jobId: "strato-save-abc", pollInterval: .milliseconds(1))
        }
    }

    // MARK: - Load and delete

    @Test("load issues snapshot-load with the vmstate node")
    func loadIssuesJob() async throws {
        let job = JobScript(jobId: "strato-load-abc")
        let transport = FakeQMPTransport(
            handler: Self.handler(job: job, queryBlock: { Self.queryBlockReply() }))

        try await Self.client(transport).loadSnapshot(
            tag: "strato-abc", vmstateNode: "#block100", devices: ["#block100", "#block200"],
            jobId: "strato-load-abc", pollInterval: .milliseconds(1))

        let load = try #require(transport.requests.first { $0["execute"] as? String == "snapshot-load" })
        let arguments = try #require(load["arguments"] as? [String: Any])
        #expect(arguments["vmstate"] as? String == "#block100")
        #expect(arguments["devices"] as? [String] == ["#block100", "#block200"])
    }

    @Test("delete names only the tag and the devices carrying it")
    func deleteIssuesJob() async throws {
        let job = JobScript(jobId: "strato-del-abc")
        let transport = FakeQMPTransport(
            handler: Self.handler(job: job, queryBlock: { Self.queryBlockReply() }))

        try await Self.client(transport).deleteSnapshot(
            tag: "strato-abc", devices: ["#block100"], jobId: "strato-del-abc",
            pollInterval: .milliseconds(1))

        let delete = try #require(
            transport.requests.first { $0["execute"] as? String == "snapshot-delete" })
        let arguments = try #require(delete["arguments"] as? [String: Any])
        #expect(arguments["tag"] as? String == "strato-abc")
        #expect(arguments["devices"] as? [String] == ["#block100"])
        // No vmstate node: a delete removes the tag wholesale.
        #expect(arguments["vmstate"] == nil)
    }

    @Test("qemu version is reported as major.minor.micro")
    func versionProbe() async throws {
        let transport = FakeQMPTransport(
            handler: Self.handler(job: JobScript(jobId: "unused"), queryBlock: { Self.queryBlockReply() }))
        #expect(try await Self.client(transport).qemuVersion() == "9.1.0")
    }
}
