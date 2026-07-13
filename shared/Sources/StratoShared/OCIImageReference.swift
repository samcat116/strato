import Foundation

/// A parsed OCI image reference (`[registry/]repository[:tag][@digest]`),
/// normalized the way Docker normalizes references so the control plane and
/// the agent agree on what a user-supplied string means.
///
/// Shared because both sides interpret references: the control plane resolves
/// tags to digests and matches pull secrets by registry host (issue #414), and
/// the agent pulls manifests and blobs for the same reference (issue #418).
public struct OCIImageReference: Sendable, Equatable {
    /// Registry host (optionally `host:port`), normalized: bare references and
    /// Docker Hub aliases (`index.docker.io`, `registry-1.docker.io`) all
    /// become `docker.io`, and the host is lowercased.
    public let registry: String
    /// Repository path within the registry, e.g. `acme/worker`. Docker Hub
    /// official images are normalized to their canonical `library/` form
    /// (`alpine` → `library/alpine`).
    public let repository: String
    /// The tag, defaulting to `latest` when the reference names none.
    public let tag: String
    /// Manifest digest (`sha256:<64 hex>`) when the reference is already
    /// pinned; nil for tag-only references.
    public let digest: String?

    /// What to ask the registry's manifest endpoint for: the digest when
    /// pinned (immutable), the tag otherwise.
    public var manifestReference: String { digest ?? tag }

    /// Base URL of the registry's distribution API. Docker Hub's API lives on
    /// `registry-1.docker.io`, not `docker.io`. Loopback registries get plain
    /// HTTP (matching Docker's built-in insecure-registry allowance for
    /// localhost); everything else is HTTPS.
    public var apiBaseURL: String {
        let host = registry == "docker.io" ? "registry-1.docker.io" : registry
        let bareHost = host.split(separator: ":").first.map(String.init) ?? host
        let scheme = (bareHost == "localhost" || bareHost.hasPrefix("127.")) ? "http" : "https"
        return "\(scheme)://\(host)"
    }

    public init(registry: String, repository: String, tag: String, digest: String? = nil) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Parses a user-supplied reference. Returns nil on malformed input (empty
    /// repository, bad digest, whitespace) rather than throwing, so callers
    /// can turn it into their own validation error.
    public static func parse(_ raw: String) -> OCIImageReference? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        // Split off the digest first: `@` can appear nowhere else.
        var remainder = trimmed
        var digest: String?
        if let at = remainder.firstIndex(of: "@") {
            let digestPart = String(remainder[remainder.index(after: at)...])
            guard isValidDigest(digestPart) else { return nil }
            digest = digestPart
            remainder = String(remainder[..<at])
        }

        // The first path component is a registry host only if it looks like
        // one (contains a dot or port colon, or is `localhost`) — Docker's
        // rule, which is what lets `alpine` and `ghcr.io/acme/worker` coexist
        // in one grammar.
        var registry = "docker.io"
        var repoAndTag = remainder
        if let slash = remainder.firstIndex(of: "/") {
            let first = String(remainder[..<slash])
            let bareFirst = first.split(separator: ":").first.map(String.init) ?? first
            if first.contains(".") || first.contains(":") || bareFirst.lowercased() == "localhost" {
                registry = first.lowercased()
                repoAndTag = String(remainder[remainder.index(after: slash)...])
            }
        }
        if registry == "index.docker.io" || registry == "registry-1.docker.io" {
            registry = "docker.io"
        }

        // Any colon left is the tag separator: port colons only occur in the
        // registry component, which is already split off.
        var repository = repoAndTag
        var tag = "latest"
        if let colon = repoAndTag.lastIndex(of: ":") {
            repository = String(repoAndTag[..<colon])
            let tagPart = String(repoAndTag[repoAndTag.index(after: colon)...])
            guard !tagPart.isEmpty, tagPart.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) })
            else { return nil }
            tag = tagPart
        }

        guard !repository.isEmpty, !repository.hasPrefix("/"), !repository.hasSuffix("/") else { return nil }
        if registry == "docker.io", !repository.contains("/") {
            repository = "library/\(repository)"
        }

        return OCIImageReference(registry: registry, repository: repository, tag: tag, digest: digest)
    }

    /// Accepts `sha256:<64 lowercase hex>` — the only algorithm in real-world
    /// use; other registered algorithms can widen this when they appear.
    public static func isValidDigest(_ digest: String) -> Bool {
        guard digest.hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }
}
