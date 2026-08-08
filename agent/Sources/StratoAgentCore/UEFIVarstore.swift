import Foundation
import Logging

public enum UEFIVarstoreError: Error, LocalizedError, ClassifiableError, Sendable {
    /// qemu-img could not be launched at all — a host problem (missing binary,
    /// not executable) rather than an operation problem.
    case toolUnavailable(String)
    /// qemu-img ran and refused, with its own output attached.
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .toolUnavailable(let detail): return detail
        case .conversionFailed(let detail): return detail
        }
    }

    public var errorDescription: String? { description }

    /// Both are permanent. The source is a static file the distro's EDK2
    /// package installed, so a conversion that fails does so for a reason no
    /// retry changes: the template is missing or unreadable, the destination
    /// filesystem is full, or the agent cannot write it. Retrying would spend
    /// the VM's whole per-generation budget re-running the same doomed command
    /// instead of reporting the remediation once.
    public var failureClassification: FailureClassification { .permanent }
}

/// Creates a VM's UEFI variable store, in the format the domain document
/// declares it in.
///
/// libvirt normally does this: given `<nvram template='…'>` it copies the
/// distro's VARS template into the VM's own varstore at first start. It will
/// not *convert* one — "conversion of the nvram template to another target
/// format is not supported" — and Strato's varstore has to be qcow2, because
/// libvirt refuses an internal snapshot of a pflash guest whose varstore is
/// anything else and that snapshot is how VM checkpoints are realized. On
/// Debian and Ubuntu, whose EDK2 descriptors all declare `raw`, those two facts
/// leave no form of the document libvirt can satisfy on its own (STR-188).
///
/// So the agent seeds the file instead, the same shape as
/// `FileSystemStorageBackend.materializeDisk`: convert once, publish
/// atomically, and never touch a file that is already there. The domain then
/// names an nvram that exists, and libvirt does no seeding at all — an existing
/// varstore is opened as pflash storage and never converted, which is the whole
/// point.
///
/// **Idempotence here is a correctness property, not a nicety.** The VM's
/// variable store is where the guest keeps its UEFI boot entries and, on a
/// Secure Boot VM, its enrolled keys. A create replayed by a level-triggered
/// sync that re-seeded this file would silently roll the guest's firmware
/// variables back to the distro's defaults, so an existing file is always left
/// alone.
public struct UEFIVarstore: Sendable {
    /// What `materialize` did, so a replayed create can be told from a first one
    /// in the log (and in tests) without inspecting the filesystem again.
    public enum Outcome: Equatable, Sendable {
        case created
        case reused
    }

    private let logger: Logger
    private let qemuImgPath: String
    private let runSubprocess: SubprocessRunner

    public init(
        logger: Logger,
        qemuImgPath: String? = nil,
        runSubprocess: @escaping SubprocessRunner = { try await ProcessRunner.run(executableURL: $0, arguments: $1) }
    ) {
        self.logger = logger
        self.qemuImgPath = qemuImgPath ?? FileSystemStorageBackend.defaultQemuImgPath
        self.runSubprocess = runSubprocess
    }

    /// Writes a qcow2 varstore at `path`, seeded from the firmware's VARS
    /// `template`, unless one is already there.
    @discardableResult
    public func materialize(at path: String, from template: String) async throws -> Outcome {
        if FileManager.default.fileExists(atPath: path) {
            logger.debug("UEFI varstore already present", metadata: ["path": .string(path)])
            return .reused
        }

        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true, attributes: nil)

        // Discard any partial output left by a previous crashed conversion.
        let stagingPath = path + ".partial"
        try? FileManager.default.removeItem(atPath: stagingPath)

        do {
            // No `-f`: the source format is whatever the host's EDK2 build
            // ships (raw on Debian/Ubuntu, qcow2 on Fedora/RHEL), and the point
            // of this call is that the agent does not have to know which. These
            // are the distro's own firmware files, so probing them is not the
            // untrusted-input hazard it would be for a guest disk — and a
            // varstore's leading bytes are an EFI variable header, which cannot
            // be mistaken for a qcow2 magic.
            let result = try await run(["convert", "-O", "qcow2", template, stagingPath])
            if result.terminationStatus != 0 {
                let output = result.combinedOutput
                logger.error(
                    "qemu-img convert failed for the UEFI varstore",
                    metadata: [
                        "template": .string(template), "path": .string(path), "output": .string(output),
                    ])
                throw UEFIVarstoreError.conversionFailed(
                    "could not convert the UEFI variable store template \(template) to qcow2 at \(path). "
                        + "qemu-img output: \(output)")
            }

            // Atomic publish, so the path only ever holds a complete varstore —
            // which is what makes the `fileExists` check above safe to trust.
            try FileManager.default.moveItem(atPath: stagingPath, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw error
        }

        logger.info(
            "UEFI varstore materialized",
            metadata: ["path": .string(path), "template": .string(template)])
        return .created
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        do {
            return try await runSubprocess(URL(fileURLWithPath: qemuImgPath), arguments)
        } catch {
            throw UEFIVarstoreError.toolUnavailable(
                "failed to launch qemu-img at \(qemuImgPath): \(error.localizedDescription). "
                    + "If QEMU tools are not installed, install them "
                    + "(Debian/Ubuntu: `apt install qemu-utils`).")
        }
    }
}
