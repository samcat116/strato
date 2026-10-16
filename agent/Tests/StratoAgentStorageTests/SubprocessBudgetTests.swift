import Foundation
import Logging
import Synchronization
import Testing
@testable import StratoAgentCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Storage subprocess budgets")
struct SubprocessBudgetTests {
    private func directory() throws -> String {
        let path = NSTemporaryDirectory() + "strato-budget-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func script(_ text: String, at path: String) throws {
        try Data(("#!/bin/sh\n" + text).utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    @Test func imageBudgetsScaleAndCapWithoutOverflow() {
        #expect(SubprocessBudget.varstore.timeout == .seconds(30))
        #expect(SubprocessBudget.imageWork(bytes: 0).timeout == .seconds(300))
        #expect(SubprocessBudget.imageWork(bytes: 1024 << 20).timeout == .seconds(1324))
        #expect(SubprocessBudget.imageWork(bytes: Int64.max).timeout == .seconds(86400))
        #expect(SubprocessBudget.imageWork(bytes: nil).timeout == .seconds(3600))
    }

    @Test(arguments: ["info", "ls", "cp", "flatten", "import"])
    func rbdBudgetsIgnoreCommandNamesInOptionValues(namespace: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/" + namespace
        try Data(repeating: 0, count: 8192).write(to: URL(fileURLWithPath: source))
        let executable = URL(fileURLWithPath: "/usr/bin/rbd")
        let common = ["--conf", namespace, "--name", namespace, "--keyring", namespace, "--namespace", namespace]
        let cases: [([String], SubprocessBudget)] = [
            (["create", "pool/image"], .mutation),
            (["info", "pool/image"], .inspection),
            (["ls", "pool"], .inspection),
            (["snap", "ls", "pool/image"], .inspection),
            (["device", "list", "--format", "json"], .inspection),
            (["cp", "pool/source", "pool/destination"], .imageWork(bytes: nil)),
            (["flatten", "pool/image"], .imageWork(bytes: nil)),
            (["import", source, "pool/image"], .imageWork(bytes: 8192)),
        ]
        for (command, expected) in cases {
            #expect(SubprocessBudget.storage(executable: executable, arguments: common + command) == expected)
            #expect(
                SubprocessBudget.storage(
                    executable: executable, arguments: ["--namespace=" + namespace] + command) == expected)
        }
    }

    @Test func realRunnerEscalatesAndReleasesSerializedStorageKeys() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let executable = root + "/qemu-img"
        let recovery = root + "/recovered"
        let pidFile = root + "/pid"
        try script(
            """
            printf partial > "$4"
            if [ ! -f '\(recovery)' ]; then
                trap '' TERM
                echo $$ > '\(pidFile)'
                while :; do :; done
            fi
            """, at: executable)
        let passedBudget = Mutex<SubprocessBudget?>(nil)
        let backend = FileSystemStorageBackend(
            logger: Logger(label: "budget-test"), volumeStoragePath: root, qemuImgPath: executable,
            runSubprocess: { executable, arguments, budget in
                passedBudget.withLock { $0 = budget }
                // Shorten the policy for this fixture, retaining the real runner,
                // process watchdog, output ceiling and signal escalation.
                return try await SubprocessBudget.run(
                    executable, arguments,
                    SubprocessBudget(timeout: .milliseconds(100), maxOutputBytes: budget.maxOutputBytes))
            })
        let queue = SerialTaskQueue()
        let outcome = Outcome()
        let started = ContinuousClock.now
        await queue.enqueue(keys: ["vm:one", "volume:one"]) {
            do {
                _ = try await backend.createVolume(volumeId: "one", sizeBytes: 1, format: .qcow2)
                await outcome.fail("hung create succeeded")
            } catch {
                await outcome.record(classification: (error as? any ClassifiableError)?.failureClassification)
                try? Data().write(to: URL(fileURLWithPath: recovery))
            }
        }
        await queue.enqueue(keys: ["vm:one", "volume:one"]) {
            do {
                let attachment = try await backend.createVolume(volumeId: "one", sizeBytes: 1, format: .qcow2)
                await outcome.finish(path: attachment.filePath)
            } catch { await outcome.fail("recovery failed: \(error)") }
        }
        await outcome.wait()
        await queue.closeAndDrain()
        #expect(ContinuousClock.now - started < .seconds(12))
        #expect(await outcome.classification == .transient)
        #expect(await outcome.failure == nil)
        #expect(await outcome.path == root + "/one/volume.qcow2")
        #expect(passedBudget.withLock { $0 } == .mutation)
        let pid = try #require(
            Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!ProcessRunner.isAlive(pid: pid))
        let files = try FileManager.default.contentsOfDirectory(atPath: root + "/one")
        // A timed-out child may have descendants; its unique staging is retained.
        #expect(files.filter { $0.hasPrefix("volume.qcow2.partial.") }.count == 1)
        #expect(FileManager.default.contents(atPath: root + "/one/volume.qcow2") == Data("partial".utf8))
    }

    @Test func outputAbortDoesNotWaitForTheImageDeadlineOrInheritedPipes() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.self) {
            try await SubprocessBudget.run(
                URL(fileURLWithPath: "/bin/sh"),
                argumentsForOutputFixture(),
                SubprocessBudget(timeout: .seconds(60), maxOutputBytes: 8))
        }
        #expect(ContinuousClock.now - started < .seconds(8))
        let result = try await SubprocessBudget.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 1234; printf 5678 >&2"],
            SubprocessBudget(timeout: .seconds(2), maxOutputBytes: 8))
        #expect(result.standardOutput.count + result.standardError.count == 8)
    }

    private func argumentsForOutputFixture() -> [String] {
        // Grandchild retains quiet pipes long after the output-producing shell
        // is killed. It exits itself, leaving no persistent fixture process.
        ["-c", "sleep 4 & printf 123456789; wait"]
    }

    @Test func timeoutRemainsBoundedAfterEarlyEOFAndDelayedExitObservation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pidFile = root + "/descendant"
        defer {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(pid, SIGKILL)
            }
        }
        let started = ContinuousClock.now
        await #expect(throws: ProcessTimedOutError.self) {
            try await SubprocessBudget.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "exec 1>&- 2>&-; sleep 20 & echo $! > '\(pidFile)'; trap '' TERM; while :; do :; done"],
                SubprocessBudget(timeout: .milliseconds(200)))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func anExitedChildWithOpenDescendantPipesCannotReportSuccess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pidFile = root + "/descendant"
        defer {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(pid, SIGKILL)
            }
        }
        let started = ContinuousClock.now
        await #expect(throws: ProcessTimedOutError.self) {
            try await SubprocessBudget.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "sleep 20 & echo $! > '\(pidFile)'; exit 0"],
                SubprocessBudget(timeout: .milliseconds(200)))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func varstoreThirtySecondWatchdogIsEffectiveWithProductionRunner() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let executable = root + "/qemu-img"
        let pidFile = root + "/pid"
        try script(
            """
            for output do :; done
            printf incomplete > "$output"
            trap '' TERM
            echo $$ > '\(pidFile)'
            while :; do :; done
            """, at: executable)
        let varstore = UEFIVarstore(logger: Logger(label: "varstore-budget"), qemuImgPath: executable)
        let started = ContinuousClock.now
        do {
            try await varstore.materialize(at: root + "/nvram.qcow2", from: root + "/template")
            Issue.record("varstore ignored its watchdog")
        } catch let error as ProcessTimedOutError {
            #expect(error.timeout == .seconds(30))
            #expect(error.failureClassification == .transient)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(30) && elapsed < .seconds(40))
        let pid = try #require(
            Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!ProcessRunner.isAlive(pid: pid))
        #expect(!FileManager.default.fileExists(atPath: root + "/nvram.qcow2"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root).contains { $0.hasPrefix("nvram.qcow2.partial.") })
    }

    @Test func cloudInitAbortRetainsBuildingStageAndRefusesRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var provisioner = CloudInitProvisioner(logger: Logger(label: "cloud-init-budget"))
        provisioner.runISO = { _, _, budget in
            #expect(budget == .cloudInit)
            return try await SubprocessBudget.run(
                URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; while :; do :; done"],
                SubprocessBudget(timeout: .milliseconds(100)))
        }
        await #expect(throws: ProcessTimedOutError.self) {
            try await provisioner.makeNoCloudISO(at: root + "/seed.iso", vmId: "one")
        }
        #expect(FileManager.default.fileExists(atPath: root + "/.cloud-init-staging/.building"))
        #expect(FileManager.default.fileExists(atPath: root + "/.cloud-init-staging/documents/user-data"))
        await #expect(throws: (any Error).self) {
            try await provisioner.makeNoCloudISO(at: root + "/seed.iso", vmId: "one")
        }
    }

    @Test func sandboxStagingWithUnconfirmedBuilderIsBlocked() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = OCIRootfsCache(rootPath: root, logger: Logger(label: "cache-budget"))
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let staging = try await cache.stagingDirectory(for: digest)
        try Data().write(to: URL(fileURLWithPath: staging + "/.building"))
        do {
            _ = try await cache.stagingDirectory(for: digest)
            Issue.record("reclaimed potentially active staging")
        } catch let error as SubprocessStagingBlockedError {
            #expect(error.failureClassification == .blocked)
        }
        #expect(FileManager.default.fileExists(atPath: staging + "/.building"))
    }

    @Test func updaterProbeAbortRetainsWorkspaceAndDoesNotSwapBinary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let binary = root + "/agent"
        let artifact = root + "/new-agent"
        try Data("old build".utf8).write(to: URL(fileURLWithPath: binary))
        try script("trap '' TERM; while :; do :; done", at: artifact)
        let updater = AgentUpdater(
            logger: Logger(label: "updater-budget"), installMode: .supervisedBinary, binaryPath: binary,
            runSubprocess: { executable, arguments, budget in
                #expect(budget == .updateProbe)
                return try await SubprocessBudget.run(
                    executable, arguments,
                    SubprocessBudget(timeout: .milliseconds(100), maxOutputBytes: budget.maxOutputBytes))
            })
        await #expect(throws: ProcessTimedOutError.self) {
            try await updater.applyUpdate(
                artifactURL: URL(fileURLWithPath: artifact).absoluteString,
                sha256: AgentUpdater.sha256Hex(ofFileAt: artifact), artifactKind: .binary, tarballMember: nil)
        }
        #expect(FileManager.default.contents(atPath: binary) == Data("old build".utf8))
        #expect(!FileManager.default.fileExists(atPath: binary + ".prev"))
        let retained = try FileManager.default.contentsOfDirectory(atPath: root).filter {
            $0.hasPrefix(".strato-agent-update-")
        }
        #expect(retained.count == 1)
        #expect(FileManager.default.fileExists(atPath: root + "/" + retained[0] + "/artifact"))
    }

    private actor Outcome {
        var classification: FailureClassification?
        var failure: String?
        var path: String?
        private var done = false
        private var waiter: CheckedContinuation<Void, Never>?
        func record(classification: FailureClassification?) { self.classification = classification }
        func finish(path: String?) { self.path = path; complete() }
        func fail(_ message: String) { failure = message; complete() }
        private func complete() { done = true; waiter?.resume(); waiter = nil }
        func wait() async {
            if done { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }
}
