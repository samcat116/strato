import Foundation
import StratoShared

/// The host side of the sandbox guest's config-drive contract (issue #421).
///
/// The guest init reads a single JSON document off a raw block device
/// (`/dev/vdb` by default) to learn its identity, where the container rootfs is,
/// and the process to launch — see `sandbox-guest/init/src/config.rs`. This type
/// is the Swift mirror of that document (`GuestConfig` on the guest side): the
/// runtime builds one per sandbox from the `SandboxSpec` and the OCI image's
/// distilled `SandboxGuestConfig`, encodes it, and writes it NUL-padded to the
/// config block device.
///
/// The schema is versioned in lockstep with the guest: both stamp
/// ``schemaVersion`` and a guest that does not recognize it refuses to launch
/// rather than guessing. Field naming deliberately matches the guest's serde
/// contract — snake_case at the top level, PascalCase inside `image_config`
/// (so the OCI image config forwards with minimal reshaping), snake_case inside
/// `overrides` — so this Codable and the Rust one stay byte-compatible.
public struct SandboxConfigDrive: Codable, Equatable, Sendable {
    /// Config-drive schema version understood by both host and guest. Must match
    /// `SCHEMA_VERSION` in the guest init.
    public static let schemaVersion: UInt32 = 1

    /// The guest vsock port the control agent listens on. Matches the guest's
    /// `DEFAULT_VSOCK_PORT`; the runtime connects here for health/status.
    public static let defaultVsockPort: UInt32 = 1024

    /// Block device the flattened container rootfs is attached as, inside the
    /// guest. The runtime attaches the rootfs as the first virtio-blk device,
    /// which the guest kernel enumerates as `/dev/vda`.
    public static let defaultRootfsDevice = "/dev/vda"

    public let schemaVersion: UInt32
    public let sandboxId: String
    public let identityNonce: String
    public let rootfs: RootfsSpec
    public let vsockPort: UInt32
    public let imageConfig: ImageConfig
    public let overrides: ProcessOverrides

    public init(
        sandboxId: String,
        identityNonce: String,
        rootfs: RootfsSpec = RootfsSpec(),
        vsockPort: UInt32 = SandboxConfigDrive.defaultVsockPort,
        imageConfig: ImageConfig,
        overrides: ProcessOverrides
    ) {
        self.schemaVersion = SandboxConfigDrive.schemaVersion
        self.sandboxId = sandboxId
        self.identityNonce = identityNonce
        self.rootfs = rootfs
        self.vsockPort = vsockPort
        self.imageConfig = imageConfig
        self.overrides = overrides
    }

    /// Build the config-drive document for a sandbox from its spec and the
    /// image's distilled guest config.
    ///
    /// The image config carries the OCI image's own entrypoint/cmd/env/etc.; the
    /// spec's overrides are forwarded separately so the *guest* performs the
    /// OCI-compatible merge (keeping that logic in exactly one place).
    public init(
        sandboxId: String,
        identityNonce: String,
        guestConfig: SandboxGuestConfig,
        spec: SandboxSpec
    ) {
        self.init(
            sandboxId: sandboxId,
            identityNonce: identityNonce,
            imageConfig: ImageConfig(
                env: guestConfig.env,
                entrypoint: guestConfig.entrypoint,
                cmd: guestConfig.cmd,
                workingDir: guestConfig.workingDir ?? "",
                user: guestConfig.user ?? ""),
            overrides: ProcessOverrides(
                entrypoint: spec.entrypoint,
                cmd: spec.cmd,
                env: spec.env,
                workdir: spec.workingDir,
                user: nil))
    }

    /// How the guest should mount the container rootfs.
    public struct RootfsSpec: Codable, Equatable, Sendable {
        public let device: String
        public let fstype: String
        public let readonly: Bool

        public init(
            device: String = SandboxConfigDrive.defaultRootfsDevice,
            fstype: String = "ext4",
            readonly: Bool = false
        ) {
            self.device = device
            self.fstype = fstype
            self.readonly = readonly
        }
    }

    /// The OCI image `config` subset the guest applies. Field names are the OCI
    /// image-spec JSON keys (PascalCase) so they forward with no reshaping.
    public struct ImageConfig: Codable, Equatable, Sendable {
        public let env: [String]
        public let entrypoint: [String]
        public let cmd: [String]
        public let workingDir: String
        public let user: String

        public init(env: [String], entrypoint: [String], cmd: [String], workingDir: String, user: String) {
            self.env = env
            self.entrypoint = entrypoint
            self.cmd = cmd
            self.workingDir = workingDir
            self.user = user
        }

        enum CodingKeys: String, CodingKey {
            case env = "Env"
            case entrypoint = "Entrypoint"
            case cmd = "Cmd"
            case workingDir = "WorkingDir"
            case user = "User"
        }
    }

    /// Sandbox-level overrides for the image config. A `nil`/empty field means
    /// "inherit from the image"; a present field replaces the image's value.
    public struct ProcessOverrides: Codable, Equatable, Sendable {
        public let entrypoint: [String]?
        public let cmd: [String]?
        public let env: [String: String]
        public let workdir: String?
        public let user: String?

        public init(
            entrypoint: [String]?, cmd: [String]?, env: [String: String], workdir: String?, user: String?
        ) {
            self.entrypoint = entrypoint
            self.cmd = cmd
            self.env = env
            self.workdir = workdir
            self.user = user
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sandboxId = "sandbox_id"
        case identityNonce = "identity_nonce"
        case rootfs
        case vsockPort = "vsock_port"
        case imageConfig = "image_config"
        case overrides
    }

    /// Encode the document as compact JSON (the guest parses raw bytes, so no
    /// pretty-printing is needed).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode a config document from a raw config block image, mirroring the
    /// guest's parse: strip the trailing NUL/whitespace padding, then decode the
    /// leading JSON. Used to recover a sandbox's identity (nonce) from its
    /// staged config drive after an agent restart.
    public static func decode(fromBlockImage data: Data) throws -> SandboxConfigDrive {
        let isPadding: (UInt8) -> Bool = { byte in
            byte == 0 || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C
                || byte == 0x0D
        }
        let end = data.lastIndex(where: { !isPadding($0) }).map { data.index(after: $0) } ?? data.startIndex
        return try JSONDecoder().decode(SandboxConfigDrive.self, from: data[data.startIndex..<end])
    }

    /// Render the config document as a raw block-device image: the JSON bytes
    /// followed by NUL padding out to a whole number of 512-byte sectors.
    ///
    /// The guest reads raw bytes off the device (there is no filesystem on the
    /// config drive) and strips trailing NUL/whitespace before parsing, so any
    /// padding beyond the document is harmless. A minimum of one sector keeps
    /// even a tiny document a valid block device.
    public func blockImage(minimumBytes: Int = 512) throws -> Data {
        var data = try encoded()
        let sector = 512
        let target = max(minimumBytes, ((data.count + sector - 1) / sector) * sector)
        if data.count < target {
            data.append(Data(repeating: 0, count: target - data.count))
        }
        return data
    }
}
