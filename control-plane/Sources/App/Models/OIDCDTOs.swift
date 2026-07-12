import Fluent
import Vapor
@preconcurrency import JWT
import Crypto
import Foundation

// OIDC data-transfer objects and JWT/JWKS crypto types, relocated out of
// OIDCController to keep the controller focused on request handling.

// MARK: - OIDC Discovery Document

struct OIDCDiscoveryDocument: Content {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let userinfoEndpoint: String?
    let jwksURI: String
    let responseTypesSupported: [String]
    let subjectTypesSupported: [String]
    let idTokenSigningAlgValuesSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case userinfoEndpoint = "userinfo_endpoint"
        case jwksURI = "jwks_uri"
        case responseTypesSupported = "response_types_supported"
        case subjectTypesSupported = "subject_types_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}

// MARK: - OIDC Authentication Data Structures

struct OIDCTokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let refreshToken: String?
    let idToken: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

struct OIDCIDTokenClaims: Content, JWTPayload, @unchecked Sendable {
    let iss: String  // Issuer
    let sub: String  // Subject
    let aud: String  // Audience
    let exp: ExpirationClaim  // Expiration time
    let iat: IssuedAtClaim  // Issued at
    let nonce: String?
    let email: String?
    let name: String?
    let preferredUsername: String?

    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
        // iat verification happens automatically
    }

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nonce, email, name
        case preferredUsername = "preferred_username"
    }
}

struct OIDCUserInfo {
    let subject: String
    let email: String?
    let name: String?
    let preferredUsername: String?
    /// Values of the provider's configured groups claim (empty when the
    /// provider has no groups claim configured or the token omits it).
    var groupValues: [String] = []
}

// MARK: - JWT and JWKS Data Structures

struct JWTHeader: Codable {
    let alg: String
    let typ: String
    let kid: String?
}

struct JWKS: Codable {
    let keys: [JWK]
}

struct JWK: Codable {
    let kty: String  // Key type (RSA)
    let use: String?  // Key usage (sig)
    let kid: String?  // Key ID
    let n: String  // RSA modulus (base64url)
    let e: String  // RSA exponent (base64url)
    let alg: String?  // Algorithm

    func createRSAPublicKey() throws -> RSAKey {
        // Decode the base64url-encoded modulus and exponent (shared, unit-tested decoder)
        let modulusData = try OIDCValidation.decodeBase64URLSafe(n)
        let exponentData = try OIDCValidation.decodeBase64URLSafe(e)

        // Create DER representation manually since we can't use internal APIs
        let derData = try createRSAPublicKeyDER(modulus: modulusData, exponent: exponentData)
        let base64String = derData.base64EncodedString()

        // Format as PEM
        let pemHeader = "-----BEGIN PUBLIC KEY-----"
        let pemFooter = "-----END PUBLIC KEY-----"

        // Split base64 string into 64-character lines
        let chunks = base64String.chunked(into: 64)
        let pemBody = chunks.joined(separator: "\n")

        let pemString = "\(pemHeader)\n\(pemBody)\n\(pemFooter)"
        return try RSAKey.public(pem: pemString)
    }

    private func createRSAPublicKeyDER(modulus: Data, exponent: Data) throws -> Data {
        // RSA Public Key DER format:
        // SEQUENCE {
        //   SEQUENCE {
        //     OBJECT IDENTIFIER rsaEncryption
        //     NULL
        //   }
        //   BIT STRING {
        //     SEQUENCE {
        //       INTEGER modulus
        //       INTEGER exponent
        //     }
        //   }
        // }

        // RSA encryption OID: 1.2.840.113549.1.1.1
        let rsaOID = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])

        // Build inner SEQUENCE with modulus and exponent
        var innerSequence = Data()
        innerSequence.append(encodeASN1Integer(modulus))
        innerSequence.append(encodeASN1Integer(exponent))
        let innerSequenceData = encodeASN1Sequence(innerSequence)

        // Build BIT STRING containing the inner sequence
        var bitString = Data([0x00])  // unused bits = 0
        bitString.append(innerSequenceData)
        let bitStringData = encodeASN1BitString(bitString)

        // Build outer SEQUENCE
        var outerSequence = Data()
        outerSequence.append(rsaOID)
        outerSequence.append(bitStringData)

        return encodeASN1Sequence(outerSequence)
    }

    private func encodeASN1Integer(_ data: Data) -> Data {
        var result = Data([0x02])  // INTEGER tag
        var integerData = data

        // Add leading zero if first bit is set (to ensure positive number)
        if let firstByte = integerData.first, firstByte & 0x80 != 0 {
            integerData.insert(0x00, at: 0)
        }

        result.append(encodeASN1Length(integerData.count))
        result.append(integerData)
        return result
    }

    private func encodeASN1Sequence(_ data: Data) -> Data {
        var result = Data([0x30])  // SEQUENCE tag
        result.append(encodeASN1Length(data.count))
        result.append(data)
        return result
    }

    private func encodeASN1BitString(_ data: Data) -> Data {
        var result = Data([0x03])  // BIT STRING tag
        result.append(encodeASN1Length(data.count))
        result.append(data)
        return result
    }

    private func encodeASN1Length(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        } else {
            let lengthBytes = withUnsafeBytes(of: length.bigEndian) { Data($0) }
                .drop { $0 == 0 }
            var result = Data([0x80 | UInt8(lengthBytes.count)])
            result.append(lengthBytes)
            return result
        }
    }

}

extension String {
    func chunked(into size: Int) -> [String] {
        return stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: min(size, count - $0))
            return String(self[start..<end])
        }
    }
}
