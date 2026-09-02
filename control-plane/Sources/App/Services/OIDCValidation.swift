import Crypto
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
        try validateOptionalHTTPSURL(request.endSessionEndpoint, label: "End session endpoint")
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
        try validateOptionalHTTPSURL(provider.endSessionEndpoint, label: "End session endpoint")
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
        try validateOptionalHTTPSURL(discovery.endSessionEndpoint, label: "Discovered end session endpoint")
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

    /// Resolves the email address to link on and whether the IdP considers it
    /// verified, merging the ID token and (optional) UserInfo claims.
    ///
    /// Some IdPs return `email` in the ID token but only assert `email_verified`
    /// in the UserInfo response, so treating the ID token's absent flag as
    /// "unverified" would wrongly block those users from linking to an existing
    /// account. Each source's flag vouches only for its own email: the ID
    /// token's `email_verified` applies to the ID token's email, and an address
    /// adopted from UserInfo needs UserInfo's own verification — otherwise an
    /// IdP asserting `email_verified: true` without an email claim would mark
    /// an unverified UserInfo-only address as verified and let it link to an
    /// existing account. An explicit `false` in the ID token always wins.
    static func resolveEmailVerification(
        idTokenEmail: String?,
        idTokenEmailVerified: Bool?,
        userInfoEmail: String?,
        userInfoEmailVerified: Bool?
    ) -> (email: String?, verified: Bool) {
        let email = idTokenEmail ?? userInfoEmail
        if idTokenEmailVerified == true, idTokenEmail != nil {
            return (email, true)
        }
        if idTokenEmailVerified != false, let verified = userInfoEmailVerified, userInfoEmail == email {
            return (email, verified)
        }
        return (email, false)
    }

    // MARK: - PKCE (RFC 7636)

    /// Generates a PKCE `code_verifier`: 32 bytes of cryptographic randomness,
    /// base64url-encoded without padding (43 characters, within the RFC 7636
    /// 43–128 range and drawn from its unreserved character set).
    static func generateCodeVerifier() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return base64URLEncode(bytes)
    }

    /// Derives the S256 `code_challenge` for a verifier:
    /// base64url(SHA256(ASCII(verifier))), unpadded (RFC 7636 §4.2).
    static func codeChallengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// Base64url without padding, as JWTs and PKCE use.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Base URL resolution

    /// Resolves the public base URL used to build OIDC redirect URIs.
    ///
    /// The `http://localhost:8080` fallback is a development convenience only:
    /// in production a silently-defaulted base URL produces redirect URIs the
    /// IdP rejects (or worse, ones that leak the authorization code to the
    /// wrong host), and the misconfiguration only surfaces as a confusing
    /// IdP-side error. Fail loudly instead.
    static func resolveBaseURL(configured: String?, environment: Environment) throws -> String {
        if let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        guard environment != .production else {
            throw Abort(
                .internalServerError,
                reason: "BASE_URL is not configured. Set it to this deployment's public origin "
                    + "(e.g. https://cloud.example.com) — OIDC redirect URIs cannot be built without it."
            )
        }
        return "http://localhost:8080"
    }

    /// Resolves the profile identity (display name / username), merging the ID
    /// token and (optional) UserInfo claims.
    ///
    /// Some IdPs (e.g. Discord) put only `sub` in the ID token and return all
    /// profile claims from the UserInfo endpoint — without this fallback such
    /// users would be created as `oidc_<subject>`. ID-token claims win when
    /// present; `nickname` is the OIDC standard claim Discord uses for the
    /// user's display name.
    static func resolveProfile(
        idTokenName: String?,
        idTokenPreferredUsername: String?,
        userInfoName: String?,
        userInfoNickname: String?,
        userInfoPreferredUsername: String?
    ) -> (name: String?, preferredUsername: String?) {
        let preferredUsername = idTokenPreferredUsername ?? userInfoPreferredUsername
        let name = idTokenName ?? userInfoName ?? userInfoNickname ?? preferredUsername
        return (name, preferredUsername)
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
        "discord.com",
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
    static func allowedHosts(configuration: ControlPlaneConfiguration) -> Set<String> {
        if let hostsString = configuration.string(.oidcDiscoveryAllowedHosts) {
            return Set(parseAllowList(hostsString))
        }
        return defaultAllowedHosts
    }

    /// Domain suffixes allowed for OIDC discovery/JWKS fetches, from
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES` (comma/semicolon separated) or `defaultAllowedDomainSuffixes`.
    static func allowedDomainSuffixes(configuration: ControlPlaneConfiguration) -> [String] {
        if let suffixesString = configuration.string(.oidcDiscoveryAllowedSuffixes) {
            return parseAllowList(suffixesString)
        }
        return defaultAllowedDomainSuffixes
    }

    /// Whether `host` falls under an allow-list suffix entry, matched on label
    /// boundaries.
    ///
    /// A bare `hasSuffix` would be a trap for operators: the shipped defaults
    /// all carry a leading dot (`.okta.com`), but an operator who sets
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES=example.com` would also be allowing
    /// `evilexample.com`. An entry without a leading dot is therefore read as
    /// "this domain and its subdomains" — `example.com` and `id.example.com`,
    /// never `evilexample.com`. An entry with one keeps its existing meaning:
    /// subdomains only (the apex, where it is trusted, is listed in
    /// `allowedHosts`). Matching is case-insensitive because DNS is.
    static func hostMatchesSuffix(_ host: String, suffix: String) -> Bool {
        let host = host.lowercased()
        let suffix = suffix.lowercased()
        guard !suffix.isEmpty else { return false }
        if suffix.hasPrefix(".") {
            return host.hasSuffix(suffix)
        }
        return host == suffix || host.hasSuffix(".\(suffix)")
    }

    /// Name-based gate for every server-side OIDC fetch (discovery, token
    /// exchange, UserInfo, JWKS): the URL must be HTTPS and its host must be
    /// allowed. Endpoints can be set manually by an org admin or copied from a
    /// discovery document, so enforcing the allow-list only on the discovery
    /// fetch is not enough — the other endpoints could otherwise be pointed at
    /// internal services.
    ///
    /// This is *one of two* gates, not the whole SSRF defense: an allow-listed
    /// name can still resolve to a private address. The fetches themselves go
    /// through `GuardedHTTPClient`, which classifies the resolved address and
    /// pins the connection to it. Keep both — the allow-list is a name-based
    /// root of trust the address classifier cannot express, and the classifier
    /// covers what a name cannot promise.
    ///
    /// Two things make a host allowed. The global allow-list
    /// (`OIDC_DISCOVERY_ALLOWED_HOSTS`/`_SUFFIXES`) is the operator's static
    /// trust and is the ONLY thing that can authorize a discovery URL — it is
    /// the root of trust, so nothing else may widen it. `perProviderHosts` is
    /// the delegated trust for the remaining fetches: hosts an already
    /// allow-listed discovery document named as its own endpoints (see
    /// `OIDCProvider.setDiscoveredHosts`). Without that delegation any IdP
    /// serving JWKS off a second domain — Google's keys live on
    /// `www.googleapis.com`, not `accounts.google.com` — would fail every login
    /// until an operator hand-edited the environment.
    static func validateAllowedFetchURL(
        _ url: String,
        label: String,
        perProviderHosts: Set<String> = [],
        configuration: ControlPlaneConfiguration
    ) throws {
        guard let parsedURL = URL(string: url),
            let host = parsedURL.host,
            parsedURL.scheme == "https"
        else {
            throw Abort(.badRequest, reason: "\(label) must be a valid HTTPS URL")
        }

        let lowercasedHost = host.lowercased()
        let isHostAllowed =
            allowedHosts(configuration: configuration).contains { $0.lowercased() == lowercasedHost }
            || allowedDomainSuffixes(configuration: configuration).contains {
                hostMatchesSuffix(host, suffix: $0)
            }
            || perProviderHosts.contains { $0.lowercased() == lowercasedHost }
        guard isHostAllowed else {
            throw Abort(
                .badRequest,
                reason:
                    "\(label) host is not in the allowed list for security reasons. If you are an administrator, set OIDC_DISCOVERY_ALLOWED_HOSTS or OIDC_DISCOVERY_ALLOWED_SUFFIXES to allow this host."
            )
        }
    }
}
