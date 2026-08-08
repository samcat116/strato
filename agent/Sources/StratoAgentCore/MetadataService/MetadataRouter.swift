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
    /// Concurrent connections per namespace listener.
    public static let maxConnections = 64
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

    public func lookup(_ name: String) -> Lookup {
        switch values[name]?.count ?? 0 {
        case 0: return .absent
        case 1: return .one(values[name]![0])
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
            [Header("content-type", "text/plain"), Header("cache-control", "no-store")] + headers
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
/// Deliberately four. The renderer trees are downstream issues — the NoCloud-net
/// document is STR-60, the EC2 tree is STR-65, `/strato/v1/identity` is STR-62 —
/// and naming an EC2-shaped key here (`local-hostname`, `placement/*`,
/// `network/interfaces/macs/...`) would commit those issues to serving it
/// forever. What is here is the smallest set that proves attribution end to end:
/// two instances on one network must read different values.
public enum MetadataDocumentPath: Sendable, Equatable, Hashable, CaseIterable {
    case root
    case metaDataIndex
    case instanceID
    case hostname
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
        // One trailing slash is the same resource; EC2 clients write both forms.
        if target.count > 1, target.hasSuffix("/") { return String(target.dropLast()) }
        return target
    }

    private static func document(for path: String) -> MetadataDocumentPath? {
        switch path {
        case "/latest": return .root
        case "/latest/meta-data": return .metaDataIndex
        case "/latest/meta-data/instance-id": return .instanceID
        case "/latest/meta-data/hostname": return .hostname
        default: return nil
        }
    }
}
