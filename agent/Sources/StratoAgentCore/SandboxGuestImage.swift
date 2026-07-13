import Foundation
import StratoShared

/// The on-disk layout of the sandbox guest base image (issue #419) and the
/// resolver that reads it.
///
/// The guest image installs as a **directory** at `sandbox_guest_image_path`
/// (default `/var/lib/strato/sandbox/guest`) containing, per architecture, an
/// uncompressed kernel (`vmlinux-<arch>`) and a gzipped-cpio initramfs
/// (`initramfs-<arch>.cpio.gz`), described by a `guest.json` manifest. The
/// build pipeline in `sandbox-guest/` produces exactly this layout.
///
/// This type is the shared contract for that layout. `SandboxRuntimeProbe`
/// only asserts the path is present (it must stay cheap and never fail a
/// capability check on a parse error); the sandbox runtime (issue #421) calls
/// ``resolve(atDirectory:architecture:fileManager:)`` to turn the directory
/// into concrete kernel/initramfs paths and boot args for Firecracker, so the
/// filenames live here rather than being hard-coded at the call site.
public struct SandboxGuestImage: Sendable, Equatable {
    /// Absolute path to the kernel image for the requested architecture.
    public let kernelPath: String
    /// Absolute path to the initramfs (`.cpio.gz`) for the requested architecture.
    public let initramfsPath: String
    /// Default kernel command line for this architecture (console + Firecracker
    /// flags). The runtime appends per-sandbox arguments (e.g. the config-drive
    /// device) to this.
    public let bootArgs: String
    /// Guest image version (`<kernel>+init<crate>`), for logging and reporting.
    public let version: String
    /// The architecture token this image was resolved for (`x86_64`/`aarch64`).
    public let arch: String

    public init(kernelPath: String, initramfsPath: String, bootArgs: String, version: String, arch: String) {
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.bootArgs = bootArgs
        self.version = version
        self.arch = arch
    }

    /// Manifest schema version this build understands.
    public static let supportedSchemaVersion = 1

    /// Manifest filename inside the guest image directory.
    public static let manifestName = "guest.json"

    /// Resolve the guest image for a host architecture from its install
    /// directory.
    ///
    /// - Parameters:
    ///   - directory: The configured `sandbox_guest_image_path`.
    ///   - architecture: Host architecture to select artifacts for; defaults
    ///     to the architecture this agent was built for.
    ///   - fileManager: Injected for testing.
    public static func resolve(
        atDirectory directory: String,
        architecture: CPUArchitecture = .current,
        fileManager: FileManager = .default
    ) throws -> SandboxGuestImage {
        let manifestPath = (directory as NSString).appendingPathComponent(manifestName)
        guard let data = fileManager.contents(atPath: manifestPath) else {
            throw SandboxGuestImageError.manifestMissing(manifestPath)
        }

        let manifest: GuestManifest
        do {
            manifest = try JSONDecoder().decode(GuestManifest.self, from: data)
        } catch {
            throw SandboxGuestImageError.manifestUnreadable("\(manifestPath): \(error)")
        }

        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw SandboxGuestImageError.unsupportedSchema(manifest.schemaVersion)
        }

        let token = architecture.guestImageArch
        guard let artifact = manifest.artifacts.first(where: { $0.arch == token }) else {
            let present = manifest.artifacts.map(\.arch).sorted().joined(separator: ", ")
            throw SandboxGuestImageError.architectureUnavailable(
                "guest image has no artifacts for \(token) (present: [\(present)])")
        }

        let kernelPath = (directory as NSString).appendingPathComponent(artifact.kernel)
        let initramfsPath = (directory as NSString).appendingPathComponent(artifact.initramfs)
        for path in [kernelPath, initramfsPath] where !fileManager.fileExists(atPath: path) {
            throw SandboxGuestImageError.artifactMissing(path)
        }

        return SandboxGuestImage(
            kernelPath: kernelPath,
            initramfsPath: initramfsPath,
            bootArgs: artifact.bootArgs,
            version: manifest.version,
            arch: artifact.arch)
    }
}

/// Failures resolving the guest image layout.
public enum SandboxGuestImageError: Error, LocalizedError, Equatable, Sendable {
    /// No `guest.json` at the expected path.
    case manifestMissing(String)
    /// `guest.json` could not be decoded.
    case manifestUnreadable(String)
    /// The manifest schema version is newer/older than this build understands.
    case unsupportedSchema(Int)
    /// The manifest has no artifacts for the host architecture.
    case architectureUnavailable(String)
    /// A kernel or initramfs named in the manifest is absent from the directory.
    case artifactMissing(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing(let path):
            return "sandbox guest manifest not found at \(path)"
        case .manifestUnreadable(let detail):
            return "sandbox guest manifest is unreadable: \(detail)"
        case .unsupportedSchema(let version):
            return "unsupported sandbox guest manifest schema version \(version) "
                + "(expected \(SandboxGuestImage.supportedSchemaVersion))"
        case .architectureUnavailable(let detail):
            return detail
        case .artifactMissing(let path):
            return "sandbox guest artifact missing: \(path)"
        }
    }
}

/// The `guest.json` manifest shape. Kept internal — callers consume the
/// resolved ``SandboxGuestImage``, not the raw manifest.
struct GuestManifest: Codable {
    let schemaVersion: Int
    let version: String
    let gitSHA: String?
    let artifacts: [Artifact]

    struct Artifact: Codable {
        let arch: String
        let kernel: String
        let initramfs: String
        let bootArgs: String
        // Checksums/sizes are present in the manifest for install-time
        // verification but are not needed to resolve boot paths, so they are
        // intentionally not decoded here.
    }
}

extension CPUArchitecture {
    /// The architecture token the guest image build uses in filenames and the
    /// manifest. The kernel/rust toolchains call ARM64 `aarch64`, whereas
    /// ``CPUArchitecture`` spells it `arm64`; this bridges the two.
    var guestImageArch: String {
        switch self {
        case .x86_64: return "x86_64"
        case .arm64: return "aarch64"
        }
    }
}
