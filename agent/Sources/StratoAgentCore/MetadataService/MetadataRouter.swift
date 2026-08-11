import Foundation

/// The request headers of the IMDSv2 handshake (STR-56).
///
/// EC2's spellings rather than Strato-prefixed ones, deliberately. What the
/// issue asked of these names is that a mint be a `PUT` carrying a *mandatory
/// custom header*, which is unreachable from a naive SSRF primitive inside a
/// guest — a property the AWS spellings have exactly as much as any other. What
/// only the AWS spellings additionally buy is that stock guest tooling can
/// complete the handshake at all: cloud-init's Ec2 datasource PUTs
/// `X-aws-ec2-metadata-token-ttl-seconds` and knows no other name, so a
/// Strato-prefixed header would have made the service unreachable from every
/// unmodified image while changing nothing an attacker cares about.
public enum MetadataHeaderName {
    /// Required on the mint. Its presence is the SSRF barrier; its value is the
    /// requested session lifetime.
    public static let tokenTTL = "x-aws-ec2-metadata-token-ttl-seconds"
    /// Required on every read.
    public static let token = "x-aws-ec2-metadata-token"
}

/// The bounds the listener enforces on what a guest may ask for. Every one of
/// these exists because the peer is untrusted guest code that can retry forever.
public enum MetadataLimits {
    /// EC2's session bounds, adopted so guest tooling's defaults land inside
    /// them (cloud-init asks for 21600).
    public static let minTokenTTLSeconds = 1
    public static let maxTokenTTLSeconds = 21600

    /// Longest request target accepted. Nothing this service serves comes close;
    /// the cap is here so a guest cannot make the agent hold a long string.
    public static let maxTargetBytes = 256
    /// Cap on the buffered request head, enforced by the decoder's
    /// `maximumBufferSize`.
    public static let maxRequestHeadBytes = 8 * 1024
    /// Concurrent connections per namespace listener, across both address
    /// families.
    public static let maxConnections = 64
    /// Concurrent connections from one source address. The namespace is shared
    /// by every guest on the network, so this is what stops one of them holding
    /// the whole budget and denying its neighbours the service.
    public static let maxConnectionsPerSource = 8
    /// How long a connection may sit without sending anything.
    public static let idleTimeoutSeconds = 10
    /// Live sessions retained per VM before the soonest-expiring is evicted. A
    /// guest can mint in a loop; this bounds what that costs the agent.
    public static let maxTokensPerVM = 32
}

// MARK: - Headers

/// Request headers, lowercased and retaining multiplicity.
///
/// Multiplicity is kept rather than collapsed because a repeated
/// authentication header is not a value to pick from: `last-wins` and
/// `first-wins` are both a guess, and the two implementations disagree about
/// which credential was presented. A duplicate is refused instead.
public struct MetadataHeaders: Sendable, Equatable {
    public enum Lookup: Sendable, Equatable {
        case absent
        case one(String)
        case duplicated
    }

    private let values: [String: [String]]

    public init(_ pairs: [(name: String, value: String)]) {
        var values: [String: [String]] = [:]
        for pair in pairs {
            values[pair.name.lowercased(), default: []].append(pair.value)
        }
        self.values = values
    }

    /// Case-insensitive in the name, exact in the value. The argument is
    /// lowercased here rather than relying on every call site passing a
    /// lowercase literal — which is what made this case-insensitive before, and
    /// would have stopped being true the first time someone passed a constant
    /// spelled any other way.
    public func lookup(_ name: String) -> Lookup {
        let matches = values[name.lowercased()] ?? []
        switch matches.count {
        case 0: return .absent
        case 1: return .one(matches[0])
        default: return .duplicated
        }
    }
}

// MARK: - Responses

/// A response, complete but for framing. Built as a value so the whole request
/// policy can be asserted without a socket.
public struct MetadataResponse: Sendable, Equatable {
    public struct Header: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public let status: Int
    public let headers: [Header]
    public let body: String

    public init(status: Int, headers: [Header] = [], body: String = "") {
        self.status = status
        // `no-store` on every response, including the failures: a token in a
        // guest's HTTP cache outlives the process that fetched it.
        self.headers =
            [
                Header("content-type", "text/plain"),
                Header("cache-control", "no-store"),
                // Every response body here is caller-influenced only through
                // what the control plane published, but a guest's browser-shaped
                // client should never be the one deciding that.
                Header("x-content-type-options", "nosniff"),
            ] + headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    static func rejected(_ status: Int, _ reason: String, headers: [Header] = []) -> MetadataResponse {
        // The body is a bare reason string, never an echo of anything the guest
        // sent: a reflected header value is how a metadata service becomes a
        // gadget in someone else's attack.
        MetadataResponse(status: status, headers: headers, body: reason)
    }
}

// MARK: - Routes

/// The documents this listener serves.
///
/// NoCloud-net documents live at the exact sibling paths cloud-init fetches.
/// EC2's `meta-data/` and `dynamic/` trees are parsed separately and rendered
/// from the same snapshot rather than copied into a second model.
public enum MetadataDocumentPath: Sendable, Equatable, Hashable {
    case root
    case noCloudMetaData
    case userData
    case networkConfig
    case ec2MetaData(EC2MetadataPath)
    case ec2Dynamic(EC2DynamicPath)
}

/// What a syntactically valid request is asking for. Nothing here has consulted
/// any state — that is `MetadataResponder`'s job.
public enum MetadataRoute: Sendable, Equatable {
    case mintToken(ttlSeconds: Int)
    case document(MetadataDocumentPath)
    /// A well-formed read of a path this service does not serve.
    ///
    /// Distinct from `.rejected` so the 404 can wait until *after* the caller
    /// has authenticated: answering "no such path" to an unauthenticated
    /// request would let anything that can reach the address map the tree
    /// without holding a session, which is most of what the handshake exists to
    /// prevent.
    case unknownDocument
    /// Refused on the request's own terms: malformed target, wrong method, a
    /// duplicated credential header. Carries the finished response so the caller
    /// has nothing to decide.
    case rejected(MetadataResponse)
}

/// Everything about a request that can be decided from the bytes alone.
///
/// Pure and dependency-free on purpose: the method/path/header rules are where
/// an IMDS's session auth is actually enforced, so they are asserted directly
/// rather than through a socket and a store.
public enum MetadataRouter {
    public static let tokenPath = "/latest/api/token"

    public static func route(method: String, target: String, headers: MetadataHeaders) -> MetadataRoute {
        guard let path = normalize(target: target) else {
            return .rejected(.rejected(400, "malformed request target"))
        }
        let method = method.uppercased()

        if path == tokenPath {
            guard method == "PUT" else {
                // A GET must never mint. This is the barrier the issue names:
                // a token obtainable by GET is a token an SSRF primitive can
                // obtain, and the whole handshake collapses to IMDSv1.
                return .rejected(
                    .rejected(405, "the token endpoint accepts PUT only", headers: [.init("allow", "PUT")]))
            }
            return mintRoute(headers: headers)
        }

        guard method == "GET" else {
            return .rejected(.rejected(405, "metadata is read-only", headers: [.init("allow", "GET")]))
        }
        // Checked here rather than at the credential check so the two possible
        // readings of a repeated header never both get evaluated.
        if headers.lookup(MetadataHeaderName.token) == .duplicated {
            return .rejected(.rejected(400, "\(MetadataHeaderName.token) given more than once"))
        }
        guard let document = document(for: path) else { return .unknownDocument }
        return .document(document)
    }

    // MARK: - Pieces

    private static func mintRoute(headers: MetadataHeaders) -> MetadataRoute {
        let raw: String
        switch headers.lookup(MetadataHeaderName.tokenTTL) {
        case .absent:
            return .rejected(.rejected(400, "missing \(MetadataHeaderName.tokenTTL)"))
        case .duplicated:
            return .rejected(.rejected(400, "\(MetadataHeaderName.tokenTTL) given more than once"))
        case .one(let value):
            raw = value
        }
        // Strictly ASCII digits: `Int("+60")` and `Int("٦٠")` both parse, and
        // neither is a TTL any client meant to send.
        guard !raw.isEmpty, raw.count <= 6, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
            let ttl = Int(raw),
            (MetadataLimits.minTokenTTLSeconds...MetadataLimits.maxTokenTTLSeconds).contains(ttl)
        else {
            return .rejected(
                .rejected(
                    400,
                    "\(MetadataHeaderName.tokenTTL) must be an integer in "
                        + "\(MetadataLimits.minTokenTTLSeconds)..\(MetadataLimits.maxTokenTTLSeconds)"))
        }
        return .mintToken(ttlSeconds: ttl)
    }

    /// The request target reduced to a path, or nil if it is not one this
    /// service will look at.
    ///
    /// No percent-decoding at all, deliberately: nothing in the served tree
    /// needs escaping, so a decoder here would exist only to be the traversal
    /// bug. A target carrying `%` is refused rather than normalized.
    private static func normalize(target: String) -> String? {
        guard target.utf8.count <= MetadataLimits.maxTargetBytes else { return nil }
        guard target.hasPrefix("/") else { return nil }
        guard !target.contains("%"), !target.contains(".."), !target.contains("?"), !target.contains("#")
        else { return nil }
        guard target.allSatisfy({ $0.isASCII && !$0.isNewline && $0 != " " }) else { return nil }
        return target
    }

    private static func document(for path: String) -> MetadataDocumentPath? {
        switch path {
        case "/latest", "/latest/": return .root
        case "/latest/meta-data": return .noCloudMetaData
        case "/latest/user-data": return .userData
        case "/latest/network-config": return .networkConfig
        default:
            // Keep the two metadata roots distinct, but preserve the
            // trailing-slash aliases previously accepted for leaf documents.
            if let components = components(below: "/latest/meta-data", in: path),
                let ec2Path = EC2MetadataPath.parse(components)
            {
                return .ec2MetaData(ec2Path)
            }
            if let components = components(below: "/latest/dynamic", in: path),
                let dynamicPath = EC2DynamicPath.parse(components)
            {
                return .ec2Dynamic(dynamicPath)
            }
            guard path.count > 1, path.hasSuffix("/"), !path.hasSuffix("//") else { return nil }
            return document(for: String(path.dropLast()))
        }
    }

    /// Splits a hierarchical EC2 path while accepting one trailing slash and
    /// rejecting empty components. Percent escapes were already refused by
    /// `normalize`, so no decoded slash can appear after this check.
    private static func components(below prefix: String, in path: String) -> [String]? {
        guard path.hasPrefix(prefix + "/") else { return nil }
        var suffix = String(path.dropFirst(prefix.count + 1))
        guard !suffix.hasPrefix("/") else { return nil }
        if suffix.hasSuffix("/") { suffix.removeLast() }
        if suffix.isEmpty { return [] }
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else { return nil }
        return components.map(String.init)
    }
}
