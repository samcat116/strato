import Foundation
import StratoShared

// Wire-format models for the OCI distribution and image specs — the subset the
// agent needs to pull a sandbox image: manifests, indexes (for platform
// selection), and the image config (for the guest-facing runtime config).
// Docker's v2 media types are aliases of the OCI ones for our purposes and
// decode through the same structures.

/// OCI/Docker media types the agent understands, and the mapping from layer
/// media type to compression algorithm.
public enum OCIMediaType {
    public static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
    public static let ociIndex = "application/vnd.oci.image.index.v1+json"
    public static let dockerManifest = "application/vnd.docker.distribution.manifest.v2+json"
    public static let dockerManifestList = "application/vnd.docker.distribution.manifest.list.v2+json"
    public static let ociConfig = "application/vnd.oci.image.config.v1+json"
    public static let dockerConfig = "application/vnd.docker.container.image.v1+json"

    /// Every manifest flavor the client accepts, for the `Accept` header on
    /// manifest requests (same set the control plane's
    /// `DistributionRegistryClient` advertises).
    public static let manifestAcceptTypes = [
        ociIndex, ociManifest, dockerManifestList, dockerManifest,
    ]

    /// True when the media type names a multi-platform index (OCI index or
    /// Docker manifest list) that must be narrowed to one platform manifest.
    public static func isIndex(_ mediaType: String) -> Bool {
        mediaType == ociIndex || mediaType == dockerManifestList
    }

    /// True when the media type names a single-platform image manifest.
    public static func isManifest(_ mediaType: String) -> Bool {
        mediaType == ociManifest || mediaType == dockerManifest
    }
}

/// Compression wrapping a layer blob's tar stream.
public enum OCILayerCompression: Sendable, Equatable {
    case none
    case gzip
    case zstd

    /// Maps a layer descriptor's media type to its compression, or nil for
    /// media types the agent cannot unpack (foreign/URL-only layers, encrypted
    /// layers, unknown future types). The deprecated `nondistributable`
    /// variants carry ordinary tar content and map like their distributable
    /// twins.
    public static func forLayerMediaType(_ mediaType: String) -> OCILayerCompression? {
        switch mediaType {
        case "application/vnd.oci.image.layer.v1.tar",
            "application/vnd.oci.image.layer.nondistributable.v1.tar",
            "application/vnd.docker.image.rootfs.diff.tar":
            return OCILayerCompression.none
        case "application/vnd.oci.image.layer.v1.tar+gzip",
            "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip",
            "application/vnd.docker.image.rootfs.diff.tar.gzip":
            return .gzip
        case "application/vnd.oci.image.layer.v1.tar+zstd",
            "application/vnd.oci.image.layer.nondistributable.v1.tar+zstd":
            return .zstd
        default:
            return nil
        }
    }
}

/// A content descriptor: how manifests point at other content (config blob,
/// layer blobs, platform manifests) by digest.
public struct OCIDescriptor: Codable, Sendable, Equatable {
    public let mediaType: String
    public let digest: String
    public let size: Int64
    /// Present only on index entries, where it names the platform the
    /// referenced manifest is built for.
    public let platform: OCIPlatform?

    public init(mediaType: String, digest: String, size: Int64, platform: OCIPlatform? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.platform = platform
    }
}

/// The platform an index entry targets, in GOARCH vocabulary (`amd64`, not
/// `x86_64`).
public struct OCIPlatform: Codable, Sendable, Equatable {
    public let architecture: String
    public let os: String
    public let variant: String?

    public init(architecture: String, os: String, variant: String? = nil) {
        self.architecture = architecture
        self.os = os
        self.variant = variant
    }

    /// Whether this platform can run on a Strato sandbox host of the given
    /// architecture. Sandboxes are Linux microVMs, so the OS must be `linux`;
    /// the architecture maps through GOARCH names, and for arm64 any of the
    /// common v8 variant spellings (or none) match.
    public func matches(_ architecture: CPUArchitecture) -> Bool {
        guard os == "linux" else { return false }
        switch architecture {
        case .x86_64:
            return self.architecture == "amd64"
        case .arm64:
            guard self.architecture == "arm64" else { return false }
            return variant == nil || variant == "v8" || variant == "8"
        }
    }
}

/// A single-platform image manifest: the config blob plus ordered layers.
public struct OCIManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let config: OCIDescriptor
    public let layers: [OCIDescriptor]

    public init(
        schemaVersion: Int = 2, mediaType: String? = OCIMediaType.ociManifest, config: OCIDescriptor,
        layers: [OCIDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
    }
}

/// A multi-platform index (OCI index / Docker manifest list).
public struct OCIIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let manifests: [OCIDescriptor]

    public init(schemaVersion: Int = 2, mediaType: String? = OCIMediaType.ociIndex, manifests: [OCIDescriptor]) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.manifests = manifests
    }
}

/// The image config blob — only the execution parameters the guest needs.
/// Field names are the spec's Go-style capitalized keys.
public struct OCIImageConfig: Codable, Sendable {
    public struct RuntimeConfig: Codable, Sendable {
        public let env: [String]?
        public let entrypoint: [String]?
        public let cmd: [String]?
        public let workingDir: String?
        public let user: String?

        enum CodingKeys: String, CodingKey {
            case env = "Env"
            case entrypoint = "Entrypoint"
            case cmd = "Cmd"
            case workingDir = "WorkingDir"
            case user = "User"
        }

        public init(
            env: [String]? = nil, entrypoint: [String]? = nil, cmd: [String]? = nil,
            workingDir: String? = nil, user: String? = nil
        ) {
            self.env = env
            self.entrypoint = entrypoint
            self.cmd = cmd
            self.workingDir = workingDir
            self.user = user
        }
    }

    public let architecture: String?
    public let os: String?
    public let config: RuntimeConfig?

    public init(architecture: String? = nil, os: String? = nil, config: RuntimeConfig? = nil) {
        self.architecture = architecture
        self.os = os
        self.config = config
    }
}

/// The execution parameters distilled from an image config for the sandbox
/// guest init (issue #419). Staged as `config.json` next to the materialized
/// rootfs; the sandbox runtime (#421) decides how it travels into the guest.
/// The guest merges `SandboxSpec` overrides over these values.
///
/// A deliberately stable, minimal schema — the guest init may not be Swift, so
/// this is a wire format: lowercase keys, arrays always present (empty, not
/// absent), `env` kept as the image's ordered `KEY=VALUE` strings.
public struct SandboxGuestConfig: Codable, Sendable, Equatable {
    public let entrypoint: [String]
    public let cmd: [String]
    public let env: [String]
    public let workingDir: String?
    public let user: String?

    public init(entrypoint: [String], cmd: [String], env: [String], workingDir: String?, user: String?) {
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.user = user
    }

    public init(imageConfig: OCIImageConfig) {
        self.init(
            entrypoint: imageConfig.config?.entrypoint ?? [],
            cmd: imageConfig.config?.cmd ?? [],
            env: imageConfig.config?.env ?? [],
            workingDir: imageConfig.config?.workingDir,
            user: imageConfig.config?.user
        )
    }
}
