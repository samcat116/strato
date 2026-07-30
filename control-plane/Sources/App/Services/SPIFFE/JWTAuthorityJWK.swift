import Foundation

/// Conversion of SPIRE's JWT authorities into a JWKS document (issue #495).
///
/// SPIRE's server API reports each JWT signing key as a DER-encoded
/// `SubjectPublicKeyInfo` plus a key ID, while JWTKit — like every JOSE
/// implementation — consumes JWKs. This is the adapter between them.
///
/// Only the key types SPIRE actually issues JWT-SVIDs with are handled: EC
/// (P-256/P-384/P-521, SPIRE's default is P-256/ES256), RSA, and Ed25519. An
/// unrecognized key is *skipped*, never guessed at: a key we cannot model is a
/// key we cannot verify against, and inventing a JWK for it would at best fail
/// later and at worst verify against the wrong material.
enum JWTAuthorityJWK {

    /// Build a JWKS document from SPIRE's JWT authorities.
    ///
    /// - Parameter authorities: `(keyID, DER SubjectPublicKeyInfo)` pairs.
    /// - Returns: a serialized JWKS, or nil when no authority could be
    ///   converted (which the caller must treat as "cannot verify", not as an
    ///   empty allow).
    static func makeJWKS(authorities: [(keyID: String, publicKeyDER: Data)]) -> Data? {
        var keys: [[String: String]] = []
        for authority in authorities {
            guard var jwk = makeJWK(publicKeyDER: authority.publicKeyDER) else { continue }
            // JWTKit selects verification keys by `kid`; an authority without
            // one cannot be addressed by a token header, so it is unusable.
            guard !authority.keyID.isEmpty else { continue }
            jwk["kid"] = authority.keyID
            jwk["use"] = "sig"
            keys.append(jwk)
        }
        guard !keys.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["keys": keys])
    }

    /// Convert one DER `SubjectPublicKeyInfo` to the JWK fields describing the
    /// key material (`kty` and its parameters). `kid`/`use` are added by the
    /// caller.
    static func makeJWK(publicKeyDER: Data) -> [String: String]? {
        guard let spki = try? parseSPKI(Array(publicKeyDER)) else { return nil }

        switch spki.algorithmOID {
        case OID.ecPublicKey:
            guard let curve = spki.parameterOID.flatMap(ECCurve.init(oid:)) else { return nil }
            // An uncompressed EC point: 0x04 || X || Y, both curve-sized.
            let point = spki.subjectPublicKey
            guard point.count == 1 + 2 * curve.coordinateBytes, point[0] == 0x04 else { return nil }
            let x = Array(point[1...curve.coordinateBytes])
            let y = Array(point[(1 + curve.coordinateBytes)...])
            return [
                "kty": "EC",
                "crv": curve.jwkName,
                "x": base64URLEncode(x),
                "y": base64URLEncode(y),
            ]

        case OID.rsaEncryption:
            // The BIT STRING wraps a DER RSAPublicKey ::= SEQUENCE { n, e }.
            guard let rsa = try? parseRSAPublicKey(spki.subjectPublicKey) else { return nil }
            return [
                "kty": "RSA",
                "n": base64URLEncode(rsa.modulus),
                "e": base64URLEncode(rsa.exponent),
            ]

        case OID.ed25519:
            // Ed25519 SPKI carries the raw 32-byte key with no inner structure.
            guard spki.subjectPublicKey.count == 32 else { return nil }
            return [
                "kty": "OKP",
                "crv": "Ed25519",
                "x": base64URLEncode(spki.subjectPublicKey),
            ]

        default:
            return nil
        }
    }

    // MARK: - Curves

    private enum ECCurve {
        case p256, p384, p521

        init?(oid: [UInt8]) {
            switch oid {
            case OID.prime256v1: self = .p256
            case OID.secp384r1: self = .p384
            case OID.secp521r1: self = .p521
            default: return nil
            }
        }

        var jwkName: String {
            switch self {
            case .p256: return "P-256"
            case .p384: return "P-384"
            case .p521: return "P-521"
            }
        }

        /// Bytes per coordinate: ceil(bits / 8), so P-521 is 66, not 65.
        var coordinateBytes: Int {
            switch self {
            case .p256: return 32
            case .p384: return 48
            case .p521: return 66
            }
        }
    }

    /// Object identifiers, as the raw contents of their DER OBJECT IDENTIFIER
    /// (without tag and length).
    private enum OID {
        /// 1.2.840.10045.2.1
        static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        /// 1.2.840.10045.3.1.7
        static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        /// 1.3.132.0.34
        static let secp384r1: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
        /// 1.3.132.0.35
        static let secp521r1: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]
        /// 1.2.840.113549.1.1.1
        static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        /// 1.3.101.112
        static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]
    }

    // MARK: - Minimal DER reading

    enum DERError: Error {
        case malformed(String)
    }

    struct SPKI {
        let algorithmOID: [UInt8]
        /// The AlgorithmIdentifier's parameters, when they are an OID (the
        /// named curve for EC keys). Absent/NULL for RSA and Ed25519.
        let parameterOID: [UInt8]?
        /// The BIT STRING contents, with the unused-bits octet stripped.
        let subjectPublicKey: [UInt8]
    }

    /// Parse `SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }`.
    static func parseSPKI(_ bytes: [UInt8]) throws -> SPKI {
        var reader = DERReader(bytes)
        var outer = DERReader(try reader.readValue(tag: 0x30))
        try reader.requireEnd("SubjectPublicKeyInfo has trailing bytes")

        var algorithm = DERReader(try outer.readValue(tag: 0x30))
        let algorithmOID = try algorithm.readValue(tag: 0x06)
        // Parameters are optional and only meaningful to us when they name a
        // curve; anything else (NULL, absent) leaves `parameterOID` nil.
        let parameterOID = algorithm.isAtEnd ? nil : try? algorithm.readValue(tag: 0x06)

        let bitString = try outer.readValue(tag: 0x03)
        guard let unusedBits = bitString.first else {
            throw DERError.malformed("Empty BIT STRING in SubjectPublicKeyInfo")
        }
        guard unusedBits == 0 else {
            throw DERError.malformed("Public-key BIT STRING has \(unusedBits) unused bits")
        }

        return SPKI(
            algorithmOID: algorithmOID,
            parameterOID: parameterOID,
            subjectPublicKey: Array(bitString.dropFirst())
        )
    }

    /// Parse `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func parseRSAPublicKey(_ bytes: [UInt8]) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        var reader = DERReader(bytes)
        var sequence = DERReader(try reader.readValue(tag: 0x30))
        let modulus = try sequence.readValue(tag: 0x02)
        let exponent = try sequence.readValue(tag: 0x02)
        // DER INTEGERs are signed, so a high bit set is preceded by a 0x00 pad
        // byte. JWK values are unsigned big-endian, so that pad must go.
        return (stripLeadingZero(modulus), stripLeadingZero(exponent))
    }

    private static func stripLeadingZero(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > 1, bytes[0] == 0x00 else { return bytes }
        return Array(bytes.dropFirst())
    }

    static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A cursor over DER values that reads one tag-length-value at a time.
    /// Deliberately minimal: it understands only the definite-length forms the
    /// structures above use.
    struct DERReader {
        private let bytes: [UInt8]
        private var index: Int

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            self.index = 0
        }

        var isAtEnd: Bool { index >= bytes.count }

        /// Read the contents of the next value, requiring it to carry `tag`.
        mutating func readValue(tag: UInt8) throws -> [UInt8] {
            guard index < bytes.count else {
                throw DERError.malformed("Expected tag 0x\(String(tag, radix: 16)), found end of data")
            }
            guard bytes[index] == tag else {
                throw DERError.malformed(
                    "Expected tag 0x\(String(tag, radix: 16)), found 0x\(String(bytes[index], radix: 16))")
            }
            index += 1

            guard index < bytes.count else {
                throw DERError.malformed("Truncated length")
            }
            let first = Int(bytes[index])
            index += 1

            var length = first
            if first >= 0x80 {
                let lengthBytes = first & 0x7F
                guard lengthBytes >= 1, lengthBytes <= 4, index + lengthBytes <= bytes.count else {
                    throw DERError.malformed("Unsupported or truncated long-form length")
                }
                length = 0
                for _ in 0..<lengthBytes {
                    length = (length << 8) | Int(bytes[index])
                    index += 1
                }
            }

            guard index + length <= bytes.count else {
                throw DERError.malformed("Value length \(length) exceeds remaining data")
            }
            let value = Array(bytes[index..<(index + length)])
            index += length
            return value
        }

        func requireEnd(_ message: String) throws {
            guard isAtEnd else { throw DERError.malformed(message) }
        }
    }
}
