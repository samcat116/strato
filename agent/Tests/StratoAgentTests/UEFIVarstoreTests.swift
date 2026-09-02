import Foundation
import Logging
import Testing

@testable import StratoAgentCore

/// The varstore the agent now writes for itself (STR-188).
///
/// libvirt would seed one from `<nvram template=…>`, and cannot, because
/// Strato's varstore must be qcow2 for VM checkpoints and no Debian or Ubuntu
/// EDK2 descriptor ships a qcow2 template — libvirt refuses the conversion
/// ("conversion of the nvram template to another target format is not
/// supported"). Every case here stubs qemu-img, so they run on a host with no
/// QEMU tools and no EDK2 installed.
@Suite("UEFI varstore materialization")
struct UEFIVarstoreTests {

    /// Records qemu-img invocations and mimics the two behaviours this type
    /// depends on: `info` reports a format, and a successful `convert` produces
    /// the file named last.
    private actor Recorder {
        private(set) var invocations: [[String]] = []
        private var exitStatus: Int32 = 0
        private var standardError = ""
        /// What `info` claims an existing file is. qcow2 by default, which is
        /// what every varstore this code wrote would report.
        private var reportedFormat = "qcow2"
        /// When set, the runner throws instead of running — a missing binary.
        private var launchFails = false

        var converts: [[String]] { invocations.filter { $0.first == "convert" } }

        func fail(status: Int32, message: String) {
            exitStatus = status
            standardError = message
        }

        func reportFormat(_ format: String) {
            reportedFormat = format
        }

        func failToLaunch() {
            launchFails = true
        }

        func run(_ arguments: [String]) throws -> ProcessResult {
            invocations.append(arguments)
            if launchFails { throw CocoaError(.fileNoSuchFile) }
            if arguments.first == "info" {
                return ProcessResult(
                    terminationStatus: exitStatus,
                    standardOutput: Data("{\"format\":\"\(reportedFormat)\"}".utf8),
                    standardError: Data(standardError.utf8))
            }
            if exitStatus == 0, let output = arguments.last {
                FileManager.default.createFile(atPath: output, contents: Data("varstore".utf8))
            }
            return ProcessResult(
                terminationStatus: exitStatus, standardOutput: Data(),
                standardError: Data(standardError.utf8))
        }

        nonisolated var runner: SubprocessRunner {
            { _, arguments in try await self.run(arguments) }
        }
    }

    /// A directory that cleans itself up, standing in for the VM's own.
    private func withTemporaryDirectory<T>(_ body: (String) async throws -> T) async throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("strato-varstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory.path)
    }

    private let logger = Logger(label: "test")

    @Test("The template is converted to qcow2 at the VM's varstore path")
    func convertsTemplateToQcow2() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(
                logger: logger, qemuImgPath: "/usr/bin/qemu-img", runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)

            try await varstore.materialize(
                at: path, from: "/usr/share/OVMF/OVMF_VARS_4M.fd")

            #expect(FileManager.default.fileExists(atPath: path))
            let invocations = await recorder.invocations
            #expect(invocations.count == 1)
            let invocation = try #require(invocations.first)
            #expect(Array(invocation.dropLast()) == ["convert", "-O", "qcow2", "/usr/share/OVMF/OVMF_VARS_4M.fd"])
            #expect(invocation.last?.hasPrefix(path + ".partial.") == true)
        }
    }

    /// The input format is deliberately not named: raw on Debian/Ubuntu, qcow2
    /// on Fedora/RHEL, and the agent should not have to know which. A `-f`
    /// here would be a claim about the host that this code is in no position
    /// to make.
    @Test("The source format is left for qemu-img to detect")
    func doesNotPinTheSourceFormat() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            try await varstore.materialize(
                at: VMDirectoryLayout.nvram(vmDirectory: directory), from: "/vars.fd")
            let arguments = try #require(await recorder.invocations.first)
            #expect(!arguments.contains("-f"))
        }
    }

    /// Idempotence is a correctness property here, not a nicety: this file is
    /// where the guest keeps its UEFI boot entries and its enrolled Secure Boot
    /// keys. A create replayed by a level-triggered sync must not roll them
    /// back to the distro's defaults, so an existing varstore is never touched
    /// — and qemu-img is not even run.
    @Test("An existing varstore is left exactly as the guest left it")
    func existingVarstoreIsNeverReseeded() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)
            let guestVariables = Data("the guest's own boot entries".utf8)
            FileManager.default.createFile(atPath: path, contents: guestVariables)

            try await varstore.materialize(at: path, from: "/vars.fd")

            // Its format is read; nothing is written. `convert` is the only
            // invocation that could touch the bytes.
            #expect(await recorder.converts.isEmpty)
            #expect(FileManager.default.contents(atPath: path) == guestVariables)
        }
    }

    /// The reuse path is not only replayed creates: a host carried over from
    /// the pre-STR-136 QEMU process driver has a **raw** `nvram.fd` at exactly
    /// this path. Reusing it under an `<nvram format='qcow2'>` defines cleanly
    /// and fails the start with an error naming a format rather than a VM —
    /// the same shape of confusion STR-188 itself was. Failing the create says
    /// which file and what to do with it.
    @Test("A varstore in the wrong format fails the create rather than the start")
    func varstoreInTheWrongFormatIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            await recorder.reportFormat("raw")
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)
            FileManager.default.createFile(atPath: path, contents: Data("a raw varstore".utf8))

            let error = await #expect(throws: UEFIVarstoreError.self) {
                try await varstore.materialize(at: path, from: "/vars.fd")
            }

            let description = try #require(error?.description)
            #expect(description.contains(path))
            #expect(description.contains("raw"))
            // Refused, not rewritten: converting a varstore the guest already
            // owns is a cutover decision, not a side effect of a create.
            #expect(await recorder.converts.isEmpty)
            #expect(FileManager.default.contents(atPath: path) == Data("a raw varstore".utf8))
        }
    }

    /// The probe is read-only, and a varstore can be open elsewhere; `-U` is
    /// what stops a lock held by a running QEMU turning a read into a failed
    /// create (the STR-193 rule, applied to the one call that inspects).
    @Test("The format probe forces sharing rather than failing on a held lock")
    func formatProbeForcesSharing() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)
            FileManager.default.createFile(atPath: path, contents: Data("varstore".utf8))

            try await varstore.materialize(at: path, from: "/vars.fd")

            let info = try #require(await recorder.invocations.first { $0.first == "info" })
            #expect(info.contains("-U"))
        }
    }

    /// A half-written varstore is worse than none: the document names the file
    /// with no template, so libvirt would hand the guest the truncated one
    /// rather than seeding a fresh one. The publish is an atomic rename for
    /// that reason, and a failed conversion must leave neither the varstore nor
    /// its staging file behind for the next attempt to trip over.
    @Test("A failed conversion leaves no varstore and no partial")
    func failedConversionLeavesNothingBehind() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            await recorder.fail(status: 1, message: "qemu-img: Could not open '/vars.fd'")
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)

            await #expect(throws: UEFIVarstoreError.self) {
                try await varstore.materialize(at: path, from: "/vars.fd")
            }

            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(partialSiblings(of: path).isEmpty)
        }
    }

    @Test("A full varstore filesystem is blocked and keeps its remedy")
    func diskFullIsBlocked() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            await recorder.fail(status: 1, message: "qemu-img: No space left on device")
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)

            let error = await #expect(throws: UEFIVarstoreError.self) {
                try await varstore.materialize(at: path, from: "/vars.fd")
            }

            guard case .insufficientDiskSpace(let reason) = error else {
                Issue.record("expected insufficientDiskSpace, got \(String(describing: error))")
                return
            }
            #expect(error?.failureClassification == .blocked)
            #expect(reason.contains("No space left on device"))
        }
    }

    /// A partial left by a crashed run is discarded rather than published: it
    /// is not a resumable download, and its bytes are the previous attempt's.
    @Test("A partial from a crashed run is discarded, not published")
    func stalePartialIsDiscarded() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let path = VMDirectoryLayout.nvram(vmDirectory: directory)
            FileManager.default.createFile(
                atPath: path + ".partial", contents: Data("half a varstore".utf8))

            try await varstore.materialize(at: path, from: "/vars.fd")

            #expect(FileManager.default.contents(atPath: path) == Data("varstore".utf8))
            #expect(!FileManager.default.fileExists(atPath: path + ".partial"))
        }
    }

    private func partialSiblings(of path: String) -> [String] {
        let directory = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".partial."
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix(prefix) }
    }

    /// The varstore lives in the VM's own directory, which on the create path
    /// exists already — but this must not depend on the order of two calls in
    /// a method it cannot see.
    @Test("The VM directory is created if it is not there yet")
    func createsTheContainingDirectory() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            let varstore = UEFIVarstore(logger: logger, runSubprocess: recorder.runner)
            let vmDirectory = (directory as NSString).appendingPathComponent("vm-0")

            try await varstore.materialize(
                at: VMDirectoryLayout.nvram(vmDirectory: vmDirectory), from: "/vars.fd")

            #expect(FileManager.default.fileExists(atPath: vmDirectory))
        }
    }

    /// A missing qemu-img is a host problem with a fix, not an opaque failure
    /// on a path an operator would read as "the VM is broken".
    @Test("A qemu-img that will not launch names the package to install")
    func missingToolNamesTheRemedy() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = Recorder()
            await recorder.failToLaunch()
            let varstore = UEFIVarstore(
                logger: logger, qemuImgPath: "/nowhere/qemu-img", runSubprocess: recorder.runner)

            let error = await #expect(throws: UEFIVarstoreError.self) {
                try await varstore.materialize(
                    at: VMDirectoryLayout.nvram(vmDirectory: directory), from: "/vars.fd")
            }

            let description = try #require(error?.description)
            #expect(description.contains("/nowhere/qemu-img"))
            #expect(description.contains("qemu-utils"))
        }
    }

    @Test("Stable varstore failures are permanent while ENOSPC is blocked")
    func failuresAreClassifiedByRemedy() {
        #expect(UEFIVarstoreError.toolUnavailable("").failureClassification == .permanent)
        #expect(UEFIVarstoreError.conversionFailed("").failureClassification == .permanent)
        #expect(UEFIVarstoreError.formatMismatch("").failureClassification == .permanent)
        #expect(UEFIVarstoreError.insufficientDiskSpace("").failureClassification == .blocked)
    }
}
