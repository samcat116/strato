import Foundation

/// RFC 8628 §3.2 device authorization response. Snake-case keys are the OAuth
/// wire format.
public struct DeviceAuthorizationResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let verificationUriComplete: String?
    public let expiresIn: Int
    public let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    public init(
        deviceCode: String,
        userCode: String,
        verificationUri: String,
        verificationUriComplete: String?,
        expiresIn: Int,
        interval: Int?
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// RFC 6749 §5.1 token response.
public struct TokenResponse: Codable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    public let refreshToken: String
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }

    public init(accessToken: String, tokenType: String, expiresIn: Int?, refreshToken: String, scope: String?) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
    }
}

/// RFC 6749 §5.2 error body.
public struct OAuthErrorBody: Codable, Sendable {
    public let error: String
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    public init(error: String, errorDescription: String?) {
        self.error = error
        self.errorDescription = errorDescription
    }
}

/// Percent-encodes a form body (`application/x-www-form-urlencoded`).
public func formEncode(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = fields.map { name, value in
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedName)=\(encodedValue)"
    }
    return Data(encoded.joined(separator: "&").utf8)
}
