import Foundation
import Vapor

/// Pure validation and parsing helpers for the OIDC flow, extracted from
/// `OIDCController` so the security-sensitive URL/allow-list/base64 logic can be
/// unit-tested without a request context. Behavior and error messages are
/// preserved exactly.
struct OIDCValidation {
    /// Validates that every provided endpoint URL is a well-formed HTTPS URL.
    static func validateURLFields(request: CreateOIDCProviderRequest) throws {
        // Validate discovery URL
        if let discoveryURL = request.discoveryURL, !discoveryURL.isEmpty {
            guard isValidHTTPSURL(discoveryURL) else {
                throw Abort(.badRequest, reason: "Discovery URL must be a valid HTTPS URL")
            }
        }

        // Validate authorization endpoint
        if let authEndpoint = request.authorizationEndpoint, !authEndpoint.isEmpty {
            guard isValidHTTPSURL(authEndpoint) else {
                throw Abort(.badRequest, reason: "Authorization endpoint must be a valid HTTPS URL")
            }
        }

        // Validate token endpoint
        if let tokenEndpoint = request.tokenEndpoint, !tokenEndpoint.isEmpty {
            guard isValidHTTPSURL(tokenEndpoint) else {
                throw Abort(.badRequest, reason: "Token endpoint must be a valid HTTPS URL")
            }
        }

        // Validate userinfo endpoint
        if let userinfoEndpoint = request.userinfoEndpoint, !userinfoEndpoint.isEmpty {
            guard isValidHTTPSURL(userinfoEndpoint) else {
                throw Abort(.badRequest, reason: "Userinfo endpoint must be a valid HTTPS URL")
            }
        }

        // Validate JWKS URI
        if let jwksURI = request.jwksURI, !jwksURI.isEmpty {
            guard isValidHTTPSURL(jwksURI) else {
                throw Abort(.badRequest, reason: "JWKS URI must be a valid HTTPS URL")
            }
        }
    }

    /// True when the string is an absolute HTTPS URL with a host.
    static func isValidHTTPSURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    /// Decodes a base64url-encoded string (JWT segment), restoring padding.
    static func decodeBase64URLSafe(_ string: String) throws -> Data {
        var base64String = string
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

    /// Hosts allowed for OIDC discovery/JWKS fetches, from
    /// `OIDC_DISCOVERY_ALLOWED_HOSTS` (comma/semicolon separated) or a built-in default set.
    static func allowedHosts(from env: Environment) -> Set<String> {
        if let hostsString = Environment.get("OIDC_DISCOVERY_ALLOWED_HOSTS") {
            // Comma or semicolon separated
            let hosts = hostsString
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(hosts)
        } else {
            // Default hosts
            return [
                "accounts.google.com",
                "login.microsoftonline.com",
                "login.salesforce.com",
                "auth0.com",
                "okta.com",
                "oauth.reddit.com",
                "github.com",
                "gitlab.com"
            ]
        }
    }

    /// Domain suffixes allowed for OIDC discovery/JWKS fetches, from
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES` (comma/semicolon separated) or a built-in default set.
    static func allowedDomainSuffixes(from env: Environment) -> [String] {
        if let suffixesString = Environment.get("OIDC_DISCOVERY_ALLOWED_SUFFIXES") {
            // Comma or semicolon separated
            let suffixes = suffixesString
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return suffixes
        } else {
            // Default suffixes
            return [
                ".auth0.com",
                ".okta.com",
                ".oktapreview.com",
                ".okta-emea.com",
                ".salesforce.com",
                ".force.com",
                ".herokuapp.com",
                ".amazonaws.com",
                ".azure.com",
                ".azurewebsites.net"
            ]
        }
    }
}
