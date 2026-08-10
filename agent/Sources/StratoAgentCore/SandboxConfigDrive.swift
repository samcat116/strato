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
/// The schema is versioned in lockstep with the guest: the host always stamps
/// the current version and a guest rejects every other version rather than
/// guessing. Field naming
/// deliberately matches the guest's serde contract — snake_case at the top
/// level, PascalCase inside `image_config` (so the OCI image config forwards
/// with minimal reshaping), snake_case inside `overrides` — so this Codable and
/// the Rust one stay byte-compatible.
public struct SandboxConfigDrive: Codable, Equatable, Sendable {
    /// Newest config-drive schema version this build writes. Must match
    /// `SCHEMA_VERSION` in the guest init.
    ///
    /// * v1 — identity, rootfs, vsock, process config.
    /// * v2 — adds the optional ``NetworkConfig`` block (STR-101).
    public static let schemaVersion: UInt32 = 2

    /// The guest vsock port the control agent listens on. Matches the guest's
    /// `DEFAULT_VSOCK_PORT`; the runtime connects here for health/status.
    public static let defaultVsockPort: UInt32 = 1024

    /// Block device the flattened container rootfs is attached as, inside the
    /// guest. The runtime attaches the rootfs as the first virtio-blk device,
    /// which the guest kernel enumerates as `/dev/vda`.
    public static let defaultRootfsDevice = "/dev/vda"

    /// Fixed block-image size every config drive is padded to (issue #426
    /// warm start). A snapshot bakes the config device's capacity into the
    /// saved virtio state, and a warm restore stages a *different* sandbox's
    /// config document at the same in-jail path — so all config drives share
    /// one capacity, making template and restored-into drives interchangeable.
    /// Documents that exceed this (pathologically large env/args) still work,
    /// but the runtime must skip warm start for them.
    public static let standardBlockImageBytes = 256 * 1024

    public let schemaVersion: UInt32
    public let sandboxId: String
    public let identityNonce: String
    public let rootfs: RootfsSpec
    public let vsockPort: UInt32
    public let imageConfig: ImageConfig
    public let overrides: ProcessOverrides
    /// Warm-start template mode (issue #426): the guest boots fully but
    /// parks `held` instead of launching a workload, waiting to be
    /// snapshotted. Encoded only when true so ordinary config documents are
    /// byte-identical to pre-warm-start ones.
    public let warmHold: Bool?
    /// Hostname the guest boots under (STR-101).
    ///
    /// Top-level rather than inside ``NetworkConfig``: a hostname belongs to
    /// the sandbox, not to its NIC. Nesting it would leave two sandboxes of one
    /// image differing in hostname purely by NIC presence, and the fork path's
    /// `reidentify` already renames every restored guest either way.
    public let hostname: String?
    /// The sandbox's single NIC, when it has one (STR-101). Encoded only when
    /// present, so a network-free sandbox's document is unchanged.
    public let network: NetworkConfig?

    public init(
        sandboxId: String,
        identityNonce: String,
        rootfs: RootfsSpec = RootfsSpec(),
        vsockPort: UInt32 = SandboxConfigDrive.defaultVsockPort,
        imageConfig: ImageConfig,
        overrides: ProcessOverrides,
        warmHold: Bool? = nil,
        hostname: String? = nil,
        network: NetworkConfig? = nil
    ) {
        self.schemaVersion = SandboxConfigDrive.schemaVersion
        self.hostname = hostname
        self.sandboxId = sandboxId
        self.identityNonce = identityNonce
        self.rootfs = rootfs
        self.vsockPort = vsockPort
        self.imageConfig = imageConfig
        self.overrides = overrides
        self.warmHold = warmHold
        self.network = network
    }

    /// Build the config-drive document for a sandbox from its spec and the
    /// image's distilled guest config.
    ///
    /// The image config carries the OCI image's own entrypoint/cmd/env/etc.; the
    /// spec's overrides are forwarded separately so the *guest* performs the
    /// OCI-compatible merge (keeping that logic in exactly one place).
    /// The hostname defaults to the id-derived label every sandbox boots under;
    /// pass one explicitly only where the caller has a different name (a
    /// warm-start template, which is not a sandbox).
    public init(
        sandboxId: String,
        identityNonce: String,
        guestConfig: SandboxGuestConfig,
        spec: SandboxSpec,
        network: NetworkConfig? = nil
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
                user: nil),
            hostname: SandboxConfigDrive.guestHostname(sandboxId: sandboxId),
            network: network)
    }

    /// The hostname a sandbox's guest boots under: a DNS-safe label derived
    /// from the sandbox id, since a sandbox has no user-chosen name. Shared
    /// with the fork re-identification path, so a restored guest is renamed
    /// under the same rule it would have booted under.
    public static func guestHostname(sandboxId: String) -> String {
        "strato-" + String(sandboxId.replacingOccurrences(of: "-", with: "").prefix(12))
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

    /// The guest's static L3 configuration for the sandbox's single NIC
    /// (STR-101).
    ///
    /// Static, not DHCP: the control plane's IPAM has already chosen the
    /// address by the time the microVM boots, so a DHCP exchange would cost a
    /// cold-start round trip (and a client binary in a size-optimized
    /// initramfs) to rediscover it. OVN's DHCP responder is still programmed
    /// for the port, so an image that runs its own client keeps working — the
    /// guest just does not depend on it, which is why this block is written
    /// even for a `dhcpEnabled` NIC.
    public struct NetworkConfig: Codable, Equatable, Sendable {
        /// MAC of the NIC to configure — how the guest picks the interface,
        /// since kernel names are enumeration order.
        public let macAddress: String?
        public let ipv4: AddressConfig?
        public let ipv6: AddressConfig?
        public let mtu: Int?
        public let nameservers: [String]
        public let searchDomains: [String]

        public init(
            macAddress: String?,
            ipv4: AddressConfig? = nil,
            ipv6: AddressConfig? = nil,
            mtu: Int? = nil,
            nameservers: [String] = [],
            searchDomains: [String] = []
        ) {
            self.macAddress = macAddress
            self.ipv4 = ipv4
            self.ipv6 = ipv6
            self.mtu = mtu
            self.nameservers = nameservers
            self.searchDomains = searchDomains
        }

        enum CodingKeys: String, CodingKey {
            case macAddress = "mac_address"
            case ipv4
            case ipv6
            case mtu
            case nameservers
            case searchDomains = "search_domains"
        }
    }

    /// One address family's assignment: address, on-link prefix, and gateway.
    /// The prefix travels as a number for both families — IPv6 has no
    /// dotted-netmask form — so the host is where a v4 netmask becomes one.
    public struct AddressConfig: Codable, Equatable, Sendable {
        public let address: String
        public let prefixLength: Int
        public let gateway: String?

        public init(address: String, prefixLength: Int, gateway: String?) {
            self.address = address
            self.prefixLength = prefixLength
            self.gateway = gateway
        }

        enum CodingKeys: String, CodingKey {
            case address
            case prefixLength = "prefix_length"
            case gateway
        }
    }

    /// Build the guest's network block from the NIC the agent actually
    /// realized.
    ///
    /// Throws when the guest could not be told how to address the NIC: an IPv4
    /// address whose netmask is missing or not a contiguous mask, an IPv6
    /// prefix out of range, or — the case the other two are guarding against in
    /// the first place — no address in either family. All three would boot a
    /// sandbox with a link-up, unaddressed interface and report it `running`,
    /// which is the exact mis-convergence in-guest networking exists to avoid,
    /// and the guest runs no DHCP client to recover from any of them.
    public static func network(
        for attachment: ResolvedNetworkAttachment
    ) throws -> NetworkConfig {
        var ipv4: AddressConfig?
        if let address = attachment.ipAddress, !address.isEmpty {
            guard let prefix = attachment.netmask.flatMap({ IPv4Address($0)?.prefixLength }) else {
                throw SandboxRuntimeError.networkingUnsupported(
                    "the NIC has IPv4 address \(address) but no usable netmask "
                        + "(\(attachment.netmask ?? "none")), so the guest cannot be told its prefix")
            }
            ipv4 = AddressConfig(
                address: address, prefixLength: prefix, gateway: nonEmpty(attachment.gateway))
        }

        var ipv6: AddressConfig?
        if let address = attachment.ip6Address, !address.isEmpty {
            // Unlike v4 there is a defensible default: /64 is the tenant
            // prefix every dual-stack LogicalNetwork allocates from, and it is
            // what the VM path's cloud-init seed already falls back to.
            let prefix = attachment.prefixLength6 ?? 64
            guard (0...128).contains(prefix) else {
                throw SandboxRuntimeError.networkingUnsupported(
                    "the NIC has IPv6 address \(address) with prefix length \(prefix), "
                        + "which is out of range")
            }
            ipv6 = AddressConfig(
                address: address, prefixLength: prefix, gateway: nonEmpty(attachment.gateway6))
        }

        // An attachment with no address at all is what the two throws above
        // exist to prevent, arrived at by a different route: IPAM allocated
        // nothing, or the fields never reached this agent. `networkingUnsupported`
        // is `.permanent`, which is right — a retry will not conjure an
        // allocation.
        guard ipv4 != nil || ipv6 != nil else {
            throw SandboxRuntimeError.networkingUnsupported(
                "the NIC on network '\(attachment.network)' carries no IPv4 or IPv6 address, and "
                    + "the guest runs no DHCP client, so it would boot with an unaddressed interface")
        }

        return NetworkConfig(
            macAddress: nonEmpty(attachment.macAddress),
            ipv4: ipv4,
            ipv6: ipv6,
            mtu: attachment.mtu,
            // Filtered to addresses that parse, and to a search domain with no
            // whitespace, for the reason `CloudInitProvisioner` filters the
            // same two fields: these land as directives in a line-oriented
            // `/etc/resolv.conf`, so anything that is not one is a character
            // that could end a line and start another. `NetworkController`'s
            // `validatedDNS`/`validatedDomainName` have gated this on write
            // since the fields' first release, so nothing reachable is dropped
            // here — the renderer just stops depending on that, as the VM path
            // already did. The guest re-checks too; neither side relies on the
            // other.
            nameservers: attachment.dnsServers.compactMap { nonEmpty($0) }
                .filter { IPv4Address($0) != nil || IPv6Address($0) != nil },
            searchDomains: [nonEmpty(attachment.domainName)].compactMap { $0 }
                .filter { domain in !domain.contains(where: { $0.isWhitespace || $0 == "#" }) })
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
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
        case warmHold = "warm_hold"
        case hostname
        case network
    }

    /// Encode the document as compact JSON (the guest parses raw bytes, so no
    /// pretty-printing is needed).
    public func encoded() throws -> Data {
        guard !sandboxId.isEmpty, !identityNonce.isEmpty else {
            throw SandboxConfigDriveError.missingIdentity
        }
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
        let drive = try JSONDecoder().decode(
            SandboxConfigDrive.self, from: data[data.startIndex..<end])
        guard drive.schemaVersion == schemaVersion else {
            throw SandboxConfigDriveError.unsupportedSchema(drive.schemaVersion)
        }
        guard !drive.sandboxId.isEmpty, !drive.identityNonce.isEmpty else {
            throw SandboxConfigDriveError.missingIdentity
        }
        return drive
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

public enum SandboxConfigDriveError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchema(UInt32)
    case missingIdentity

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "unsupported sandbox config-drive schema version \(version); "
                + "schema \(SandboxConfigDrive.schemaVersion) is required, so recreate the sandbox "
                + "or purge and recapture its checkpoint with a current guest image"
        case .missingIdentity:
            return "sandbox config drive is missing its sandbox identity or identity nonce; "
                + "recreate the sandbox or purge and recapture its checkpoint"
        }
    }
}
