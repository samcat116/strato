import Foundation

/// Failures across the OCI pull → unpack → rootfs-build pipeline, classified
/// for the reconciler the same way `ImageCacheError` is: transient failures
/// are worth the per-generation retry budget, permanent ones are reported
/// once with their remediation.
public enum OCIError: Error, LocalizedError, ClassifiableError {
    /// The image reference string does not parse.
    case invalidReference(String)
    /// The sync-provided credential is already past its expiry: the pull is
    /// doomed, so skip it and let the next sync deliver fresh material.
    case credentialExpired(registry: String)
    /// The registry's Bearer token realm is plaintext HTTP on a non-loopback
    /// host; credentials must never travel toward it (mirrors the control
    /// plane's `RegistryClientError.insecureTokenRealm`).
    case insecureTokenRealm(registry: String, realm: String)
    /// Authentication failed after running the registry's challenge flow
    /// (bad credential, insufficient scope, unusable token endpoint).
    case authenticationFailed(registry: String, detail: String)
    /// The registry answered a manifest request with a terminal error status.
    case manifestUnavailable(reference: String, status: Int)
    /// A blob the manifest references cannot be fetched (terminal status).
    case blobUnavailable(digest: String, status: Int)
    /// A network-level or retryable-status failure that survived all retries.
    case transferFailed(detail: String)
    /// The registry served something structurally wrong (undecodable JSON,
    /// missing headers, redirect without Location, malformed digest).
    case malformedResponse(detail: String)
    /// A redirect chain exceeded the follow limit.
    case tooManyRedirects(url: String)
    /// Fetched content does not hash to the digest that named it.
    case digestMismatch(expected: String, actual: String)
    /// The index has no manifest for this host's platform.
    case noMatchingPlatform(reference: String, architecture: String)
    /// A manifest or layer uses a media type the agent cannot process.
    case unsupportedMediaType(String)
    /// A layer's tar stream is malformed or contains entries that would
    /// escape the rootfs tree. Content is immutable for a pinned digest, so
    /// retrying can never help.
    case layerUnpackFailed(detail: String)
    /// Not enough free space for the projected pull + unpack + image build.
    case insufficientDiskSpace(detail: String)
    /// A host prerequisite is missing or broken (no mkfs.ext4, no gzip/zstd,
    /// unwritable cache directory).
    case hostMisconfiguration(detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference(let raw):
            return "Invalid OCI image reference: \(raw)"
        case .credentialExpired(let registry):
            return "Registry credential for \(registry) is expired; waiting for a fresh sync"
        case .insecureTokenRealm(let registry, let realm):
            return
                "Registry \(registry) advertises a plaintext token realm (\(realm)); refusing to send credentials"
        case .authenticationFailed(let registry, let detail):
            return "Authentication with registry \(registry) failed: \(detail)"
        case .manifestUnavailable(let reference, let status):
            return "Registry returned HTTP \(status) for manifest \(reference)"
        case .blobUnavailable(let digest, let status):
            return "Registry returned HTTP \(status) for blob \(digest)"
        case .transferFailed(let detail):
            return "Registry transfer failed: \(detail)"
        case .malformedResponse(let detail):
            return "Malformed registry response: \(detail)"
        case .tooManyRedirects(let url):
            return "Too many redirects fetching \(url)"
        case .digestMismatch(let expected, let actual):
            return "Content digest mismatch. Expected: \(expected), Actual: \(actual)"
        case .noMatchingPlatform(let reference, let architecture):
            return "Image \(reference) has no manifest for linux/\(architecture)"
        case .unsupportedMediaType(let mediaType):
            return "Unsupported OCI media type: \(mediaType)"
        case .layerUnpackFailed(let detail):
            return "Layer unpack failed: \(detail)"
        case .insufficientDiskSpace(let detail):
            return "Insufficient disk space: \(detail)"
        case .hostMisconfiguration(let detail):
            return "Host misconfiguration: \(detail)"
        }
    }

    public var failureClassification: FailureClassification {
        switch self {
        case .invalidReference, .insecureTokenRealm, .noMatchingPlatform, .unsupportedMediaType,
            .manifestUnavailable, .blobUnavailable, .layerUnpackFailed, .insufficientDiskSpace,
            .hostMisconfiguration:
            // Nothing on this host will change these: the reference, the
            // registry's content for a pinned digest, and missing host
            // prerequisites are all stable until an operator (or a spec
            // change) intervenes.
            return .permanent
        case .credentialExpired, .authenticationFailed, .transferFailed, .malformedResponse,
            .tooManyRedirects, .digestMismatch:
            // Credentials are re-minted at every sync assembly and network
            // corruption is by nature retryable, so these can self-heal.
            return .transient
        }
    }
}
