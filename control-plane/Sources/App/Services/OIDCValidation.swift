import Foundation
import Vapor

/// Pure validation and parsing helpers for the OIDC flow, extracted from
/// `OIDCController` so the security-sensitive URL/allow-list/base64 logic can be
/// unit-tested without a request context. Behavior and error messages are
/// preserved exactly.
struct OIDCValidation {
    /// Validates that every provided endpoint URL is a well-formed HTTPS URL.
    static func validateURLFields(request: CreateOIDCProviderRequest) throws {
        try validateOptionalHTTPSURL(request.discoveryURL, label: "Discovery URL")
        try validateOptionalHTTPSURL(request.authorizationEndpoint, label: "Authorization endpoint")
        try validateOptionalHTTPSURL(request.tokenEndpoint, label: "Token endpoint")
        try validateOptionalHTTPSURL(request.userinfoEndpoint, label: "Userinfo endpoint")
        try validateOptionalHTTPSURL(request.jwksURI, label: "JWKS URI")
    }

    /// Validates the endpoint URLs stored on a provider. The update path
    /// mutates fields individually rather than through a create request, so it
    /// validates the resulting model state with this before saving — otherwise
    /// an edit could store an http:// token endpoint that later receives the
    /// client secret.
    static func validateURLFields(provider: OIDCProvider) throws {
        try validateOptionalHTTPSURL(provider.discoveryURL, label: "Discovery URL")
        try validateOptionalHTTPSURL(provider.authorizationEndpoint, label: "Authorization endpoint")
        try validateOptionalHTTPSURL(provider.tokenEndpoint, label: "Token endpoint")
        try validateOptionalHTTPSURL(provider.userinfoEndpoint, label: "Userinfo endpoint")
        try validateOptionalHTTPSURL(provider.jwksURI, label: "JWKS URI")
    }

    /// Validates the endpoint URLs in a fetched discovery document before they
    /// are copied onto a provider. An allow-listed discovery host can still
    /// serve an http:// or malformed token_endpoint — which would later
    /// receive the client secret — so discovered values get the same HTTPS
    /// validation as manually entered ones.
    static func validateDiscoveredEndpoints(_ discovery: OIDCDiscoveryDocument) throws {
        try validateOptionalHTTPSURL(discovery.authorizationEndpoint, label: "Discovered authorization endpoint")
        try validateOptionalHTTPSURL(discovery.tokenEndpoint, label: "Discovered token endpoint")
        try validateOptionalHTTPSURL(discovery.userinfoEndpoint, label: "Discovered userinfo endpoint")
        try validateOptionalHTTPSURL(discovery.jwksURI, label: "Discovered JWKS URI")
    }

    /// Whether an ID token's `iss` claim satisfies the provider's expected issuer.
    ///
    /// Usually an exact string compare, but multi-tenant discovery documents
    /// return a *templated* issuer: Microsoft Entra's `common`/`organizations`
    /// endpoints advertise `https://login.microsoftonline.com/{tenantid}/v2.0`,
    /// while a real token carries the concrete tenant, e.g.
    /// `https://login.microsoftonline.com/<guid>/v2.0`. Exact equality would
    /// reject every otherwise-valid login for such providers. Any `{...}`
    /// placeholder in the expected issuer is therefore matched as exactly one
    /// path segment (`[^/]+`) — permissive enough for the tenant substitution,
    /// tight enough that it can't span extra `/`-delimited segments.
    ///
    /// A single trailing slash is treated as insignificant on both sides: the
    /// discovery URL (`.../.well-known/openid-configuration`) is identical whether
    /// the issuer is `https://x` or `https://x/`, so a URL-derived issuer can't
    /// know which form the IdP uses (Google omits it, Auth0 includes it). The two
    /// forms denote the same issuer, so normalizing the slash can't match a
    /// different issuer.
    static func issuerMatches(expected: String, actual: String) -> Bool {
        func trimTrailingSlash(_ s: String) -> String {
            s.hasSuffix("/") ? String(s.dropLast()) : s
        }
        let expected = trimTrailingSlash(expected)
        let actual = trimTrailingSlash(actual)

        if expected == actual { return true }
        // Only templated issuers need pattern matching; a plain mismatch fails.
        guard expected.contains("{") else { return false }

        // Swap each {placeholder} for a sentinel that survives regex-escaping
        // (letters/underscores are not metacharacters), escape the literal parts,
        // then turn the sentinel into a single-segment wildcard and anchor it.
        let sentinel = "\u{1}OIDCTENANTWILDCARD\u{1}"
        let templated = expected.replacingOccurrences(
            of: "\\{[^}]+\\}", with: sentinel, options: .regularExpression)
        let escaped = NSRegularExpression.escapedPattern(for: templated)
        let pattern = "^" + escaped.replacingOccurrences(of: sentinel, with: "[^/]+") + "$"

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(actual.startIndex..<actual.endIndex, in: actual)
        return regex.firstMatch(in: actual, range: range) != nil
    }

    /// The well-known suffix a discovery URL appends to the issuer
    /// (OpenID Connect Discovery 1.0 §4).
    static let discoveryWellKnownSuffix = "/.well-known/openid-configuration"

    /// Best-effort derivation of a provider's expected issuer from its discovery
    /// URL, without a network fetch — used to backfill existing providers on
    /// upgrade so `iss` validation applies immediately. Returns nil when the
    /// issuer can't be derived confidently, in which case the caller leaves it
    /// unset (the provider fails closed until an admin refresh stores the real
    /// metadata issuer).
    ///
    /// Rules:
    ///  * Non-Microsoft hosts: a spec-compliant discovery URL is
    ///    `issuer + suffix`, so the stripped URL is the exact issuer — including
    ///    hosts whose path happens to contain `/common/` etc.
    ///  * Microsoft Entra `login.microsoftonline.com`:
    ///    - v2.0 endpoints (`.../{tenant}/v2.0`): issuer is
    ///      `.../{tenant}/v2.0`. Multi-tenant aliases (`common`/`organizations`/
    ///      `consumers`) are templated to `{tenantid}`; a concrete tenant GUID is
    ///      exact.
    ///    - v1 endpoints (no `/v2.0`): the issuer lives on a *different* host,
    ///      `https://sts.windows.net/{tenantid}/`, so it can't be recovered by
    ///      stripping. Emit that form — templated for a multi-tenant alias,
    ///      concrete for a specific tenant GUID. `issuerMatches` validates both.
    ///
    ///    A Microsoft tenant segment that is a *domain* authority (e.g.
    ///    `contoso.onmicrosoft.com`) resolves in metadata to the tenant's GUID
    ///    issuer, which the URL doesn't contain — so it's returned as
    ///    unbackfillable (nil) rather than stored as the (wrong) domain URL.
    static func discoveryIssuer(forDiscoveryURL url: String) -> String? {
        guard url.hasSuffix(discoveryWellKnownSuffix) else { return nil }
        let base = String(url.dropLast(discoveryWellKnownSuffix.count))
        guard let parsed = URL(string: base), let host = parsed.host else { return nil }

        guard host == "login.microsoftonline.com" else {
            // Non-Microsoft: the stripped URL is the issuer.
            return base
        }

        let segments = parsed.path.split(separator: "/").map(String.init)
        let multiTenantAliases: Set<String> = ["common", "organizations", "consumers"]
        let tenant = segments.first
        let isAlias = tenant.map { multiTenantAliases.contains($0) } ?? false
        // Only a tenant GUID appears verbatim in the issuer; a domain authority
        // resolves to a GUID we can't derive from the URL.
        let isGUID = tenant.flatMap { UUID(uuidString: $0) } != nil
        let isV2 = segments.last == "v2.0"

        if isV2 {
            if isAlias {
                return "https://login.microsoftonline.com/{tenantid}/v2.0"
            }
            return isGUID ? base : nil
        }
        // v1: issuer host is sts.windows.net.
        if isAlias {
            return "https://sts.windows.net/{tenantid}/"
        }
        if let tenant, isGUID {
            return "https://sts.windows.net/\(tenant)/"
        }
        return nil
    }

    /// Resolves the email address to link on and whether the IdP considers it
    /// verified, merging the ID token and (optional) UserInfo claims.
    ///
    /// Some IdPs return `email` in the ID token but only assert `email_verified`
    /// in the UserInfo response, so treating the ID token's absent flag as
    /// "unverified" would wrongly block those users from linking to an existing
    /// account. The UserInfo flag is consulted only when the ID token omits its
    /// own (an explicit `false` in the ID token is respected) and only for the
    /// *same* address that will be linked, so it can't verify a different email.
    static func resolveEmailVerification(
        idTokenEmail: String?,
        idTokenEmailVerified: Bool?,
        userInfoEmail: String?,
        userInfoEmailVerified: Bool?
    ) -> (email: String?, verified: Bool) {
        let email = idTokenEmail ?? userInfoEmail
        if idTokenEmailVerified == true {
            return (email, true)
        }
        if idTokenEmailVerified == nil, let verified = userInfoEmailVerified, userInfoEmail == email {
            return (email, verified)
        }
        return (email, false)
    }

    private static func validateOptionalHTTPSURL(_ urlString: String?, label: String) throws {
        if let urlString, !urlString.isEmpty {
            guard isValidHTTPSURL(urlString) else {
                throw Abort(.badRequest, reason: "\(label) must be a valid HTTPS URL")
            }
        }
    }

    /// True when the string is an absolute HTTPS URL with a host.
    static func isValidHTTPSURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
            let scheme = url.scheme,
            scheme == "https",
            url.host != nil
        else {
            return false
        }
        return true
    }

    /// Decodes a base64url-encoded string (JWT segment), restoring padding.
    static func decodeBase64URLSafe(_ string: String) throws -> Data {
        var base64String =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if necessary
        let paddingLength = (4 - base64String.count % 4) % 4
        base64String += String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: base64String) else {
            throw Abort(.badRequest, reason: "Invalid base64 encoding")
        }

        return data
    }

    // MARK: - SSRF allow-lists for discovery/JWKS fetching

    /// Hosts allowed for OIDC discovery/JWKS fetches when
    /// `OIDC_DISCOVERY_ALLOWED_HOSTS` is not set.
    static let defaultAllowedHosts: Set<String> = [
        "accounts.google.com",
        "login.microsoftonline.com",
        "login.salesforce.com",
        "auth0.com",
        "okta.com",
        "oauth.reddit.com",
        "github.com",
        "gitlab.com",
    ]

    /// Domain suffixes allowed for OIDC discovery/JWKS fetches when
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES` is not set.
    static let defaultAllowedDomainSuffixes: [String] = [
        ".auth0.com",
        ".okta.com",
        ".oktapreview.com",
        ".okta-emea.com",
        ".salesforce.com",
        ".force.com",
        ".herokuapp.com",
        ".amazonaws.com",
        ".azure.com",
        ".azurewebsites.net",
    ]

    /// Splits a comma/semicolon-separated allow-list, trimming and dropping empties.
    static func parseAllowList(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Hosts allowed for OIDC discovery/JWKS fetches, from
    /// `OIDC_DISCOVERY_ALLOWED_HOSTS` (comma/semicolon separated) or `defaultAllowedHosts`.
    static func allowedHosts() -> Set<String> {
        if let hostsString = Environment.get("OIDC_DISCOVERY_ALLOWED_HOSTS") {
            return Set(parseAllowList(hostsString))
        }
        return defaultAllowedHosts
    }

    /// Domain suffixes allowed for OIDC discovery/JWKS fetches, from
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES` (comma/semicolon separated) or `defaultAllowedDomainSuffixes`.
    static func allowedDomainSuffixes() -> [String] {
        if let suffixesString = Environment.get("OIDC_DISCOVERY_ALLOWED_SUFFIXES") {
            return parseAllowList(suffixesString)
        }
        return defaultAllowedDomainSuffixes
    }
}
