import Crypto
import Foundation

/// Token formatting for the OAuth 2.0 Device Authorization Grant. Durable
/// state lives in `OAuthDeviceSessionsPersistence`.
enum DeviceAuthorization {
    static let userCodeCharset = "BCDFGHJKLMNPQRSTVWXZ"

    static func generateDeviceCode() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(40)
        return "dc_\(keyString)"
    }

    static func generateUserCode() -> String {
        let group = { String((0..<4).map { _ in userCodeCharset.randomElement()! }) }
        return "\(group())-\(group())"
    }

    static func hashCode(_ code: String) -> String {
        let data = Data(code.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func normalizeUserCode(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0 != "-" && $0 != " " }
        guard cleaned.count == 8 else { return raw.uppercased() }
        let mid = cleaned.index(cleaned.startIndex, offsetBy: 4)
        return "\(cleaned[..<mid])-\(cleaned[mid...])"
    }
}
