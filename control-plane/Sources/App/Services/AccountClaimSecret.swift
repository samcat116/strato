import Crypto
import Foundation

/// Creates and hashes account-claim bearer secrets. Persistence receives only
/// the digest; the raw token exists in the application only long enough to be
/// returned or printed once.
enum AccountClaimSecret {
    static func generateToken() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)

        return "claim_\(keyString)"
    }

    static func hashToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func extractPrefix(_ token: String) -> String {
        String(token.prefix(20))
    }
}
