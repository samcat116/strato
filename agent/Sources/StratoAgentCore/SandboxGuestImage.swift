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
/// only asserts the path is present for the base sandbox capability (that
/// check must stay cheap and never go dark on a parse error); the sandbox
/// runtime (issue #421) calls ``resolve(atDirectory:architecture:fileManager:)``
/// to turn the directory into concrete kernel/initramfs paths and boot args for
/// Firecracker, so the filenames live here rather than being hard-coded at the
/// call site.
///
/// The manifest also carries what the installed guest can *do*
/// (``capabilities``), which is a separate question from what the agent binary
/// can do: the two are distributed independently, so a current agent is
/// routinely paired with a guest image several releases behind. STR-103 reads
/// the networking capability from here at every registration.
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
    /// What this guest build can do beyond booting a workload — see
    /// ``GuestCapability``. Empty for a v1 manifest, which predates the field.
    public let capabilities: Set<String>

    public init(
        kernelPath: String, initramfsPath: String, bootArgs: String, version: String, arch: String,
        capabilities: Set<String> = []
    ) {
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.bootArgs = bootArgs
        self.version = version
        self.arch = arch
        self.capabilities = capabilities
    }

    /// Capability tokens a `guest.json` may advertise (manifest schema v2+).
    ///
    /// A named list rather than a config-drive version number: what the host
    /// needs to know is whether *this* guest realizes a feature, and a schema
    /// number can only ever be a proxy for that — an initramfs built without
    /// the interface bring-up path would still parse a v2 document.
    public enum GuestCapability {
        /// The init understands the config drive's `network` block and brings
        /// the interface up from it (STR-101). Without this, a document
        /// carrying a NIC is refused by the guest — which is why the agent
        /// must not advertise sandbox networking on such an image.
        public static let network = "network"
    }

    /// Whether the installed guest brings up a NIC from the config drive.
    public var supportsNetworking: Bool { capabilities.contains(GuestCapability.network) }

    /// The oldest manifest schema this build still reads. Every version in
    /// ``supportedSchemaVersions`` is accepted, mirroring the config drive's
    /// own `MINIMUM_SCHEMA_VERSION...SCHEMA_VERSION` rule — and for the same
    /// reason: the guest image is installed separately from the agent, so
    /// "agent newer than image" is the normal rollout state, not an error.
    public static let minimumSchemaVersion = 1

    /// Newest manifest schema version this build understands.
    ///
    /// * v1 — schema version, image version, git SHA, per-arch artifacts.
    /// * v2 — adds the top-level `capabilities` list (STR-103).
    public static let supportedSchemaVersion = 2

    /// The accepted manifest schema range.
    public static var supportedSchemaVersions: ClosedRange<Int> {
        minimumSchemaVersion...supportedSchemaVersion
    }

    /// Manifest filename inside the guest image directory.
    public static let manifestName = "guest.json"

    /// The capabilities the installed guest advertises, without resolving any
    /// artifact.
    ///
    /// Split out from ``resolve(atDirectory:architecture:fileManager:)`` for
    /// the registration probe: it runs on every reconnect and asks only what
    /// the guest can do, so requiring the host architecture's kernel and
    /// initramfs to be present would answer a different question — and answer
    /// it with an error that belongs to the base sandbox capability, not to
    /// networking.
    public static func capabilities(
        atDirectory directory: String,
        fileManager: FileManager = .default
    ) throws -> Set<String> {
        Set(try manifest(atDirectory: directory, fileManager: fileManager).capabilities ?? [])
    }

    /// Read, decode and version-check the manifest.
    private static func manifest(
        atDirectory directory: String,
        fileManager: FileManager
    ) throws -> GuestManifest {
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

        guard supportedSchemaVersions.contains(manifest.schemaVersion) else {
            throw SandboxGuestImageError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

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
        let manifest = try manifest(atDirectory: directory, fileManager: fileManager)

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
            arch: artifact.arch,
            capabilities: Set(manifest.capabilities ?? []))
    }
}

/// Failures resolving the guest image layout.
public enum SandboxGuestImageError: Error, LocalizedError, Equatable, Sendable {
    /// No `guest.json` at the expected path.
    case manifestMissing(String)
    /// `guest.json` could not be decoded.
    case manifestUnreadable(String)
    /// The manifest schema version is outside the range this build reads.
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
                + "(this agent reads \(SandboxGuestImage.minimumSchemaVersion)"
                + "...\(SandboxGuestImage.supportedSchemaVersion))"
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
    /// Schema v2+ (STR-103). Optional rather than defaulted so a v1 manifest —
    /// which predates the field entirely — decodes to nil and reads as "this
    /// guest advertises nothing", which is the safe answer for every
    /// capability the host might ask about.
    let capabilities: [String]?
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
