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

    /// Records qemu-img invocations and mimics its one side effect: a
    /// successful `convert` produces the file named last.
    private actor Recorder {
        private(set) var invocations: [[String]] = []
        private var exitStatus: Int32 = 0
        private var standardError = ""
        /// When set, the runner throws instead of running — a missing binary.
        private var launchFails = false

        func fail(status: Int32, message: String) {
            exitStatus = status
            standardError = message
        }

        func failToLaunch() {
            launchFails = true
        }

        func run(_ arguments: [String]) throws -> ProcessResult {
            invocations.append(arguments)
            if launchFails { throw CocoaError(.fileNoSuchFile) }
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

            let outcome = try await varstore.materialize(
                at: path, from: "/usr/share/OVMF/OVMF_VARS_4M.fd")

            #expect(outcome == .created)
            #expect(FileManager.default.fileExists(atPath: path))
            let invocations = await recorder.invocations
            #expect(
                invocations == [
                    ["convert", "-O", "qcow2", "/usr/share/OVMF/OVMF_VARS_4M.fd", path + ".partial"]
                ])
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

            let outcome = try await varstore.materialize(at: path, from: "/vars.fd")

            #expect(outcome == .reused)
            #expect(await recorder.invocations.isEmpty)
            #expect(FileManager.default.contents(atPath: path) == guestVariables)
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
            #expect(!FileManager.default.fileExists(atPath: path + ".partial"))
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
        }
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

    /// The template is a static file the distro's EDK2 package installed, so
    /// nothing about a failed conversion self-heals. Saying so is what stops
    /// the reconciler spending a VM's whole per-generation retry budget
    /// re-running the same doomed qemu-img instead of reporting the fix once.
    @Test("A varstore failure is permanent, so the reconciler stops rather than retries")
    func failuresAreClassifiedPermanent() {
        #expect(UEFIVarstoreError.toolUnavailable("").failureClassification == .permanent)
        #expect(UEFIVarstoreError.conversionFailed("").failureClassification == .permanent)
    }
}
