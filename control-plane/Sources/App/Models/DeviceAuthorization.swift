import Crypto
import Fluent
import Foundation
import Vapor

/// A pending OAuth 2.0 Device Authorization Grant (RFC 8628) request.
///
/// Created when a CLI calls `POST /oauth/device_authorization`; the user
/// approves or denies the request at `/activate` while the CLI polls
/// `POST /oauth/token` with the device code. Only the SHA-256 hash of the
/// device code is stored (mirroring `AccountClaimToken`); the user code is
/// stored in the clear because it is short-lived, low-entropy by design, and
/// only resolvable through session-authenticated endpoints.
final class DeviceAuthorization: Model, @unchecked Sendable {
    static let schema = "oauth_device_authorizations"

    /// Approval lifecycle. Stored as a plain string column, not a database
    /// enum, so rows can never trap FluentKit's persisted-@Enum decoding.
    enum Status: String {
        case pending
        case approved
        case denied
        case redeemed
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "device_code_hash")
    var deviceCodeHash: String

    @Field(key: "user_code")
    var userCode: String

    @Field(key: "client_name")
    var clientName: String

    @Field(key: "scopes")
    var scopes: [String]

    @Field(key: "status")
    var status: String

    /// The user who approved or denied the request; nil while pending.
    @OptionalParent(key: "user_id")
    var user: User?

    @OptionalField(key: "request_ip")
    var requestIP: String?

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "last_polled_at")
    var lastPolledAt: Date?

    @Field(key: "poll_interval")
    var interval: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        deviceCodeHash: String,
        userCode: String,
        clientName: String,
        scopes: [String],
        requestIP: String?,
        expiresAt: Date,
        interval: Int
    ) {
        self.id = id
        self.deviceCodeHash = deviceCodeHash
        self.userCode = userCode
        self.clientName = clientName
        self.scopes = scopes
        self.status = Status.pending.rawValue
        self.requestIP = requestIP
        self.expiresAt = expiresAt
        self.interval = interval
    }

    // MARK: - Code generation

    /// RFC 8628 §6.1 recommends a user-code alphabet without vowels or easily
    /// confused characters so codes are easy to read over the phone and can't
    /// spell words. 8 characters in two groups: `XXXX-XXXX`.
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

    /// Uppercases and re-inserts the dash so users can type codes in any of
    /// the obvious shapes (`bcdf-ghjk`, `BCDFGHJK`, ...).
    static func normalizeUserCode(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0 != "-" && $0 != " " }
        guard cleaned.count == 8 else { return raw.uppercased() }
        let mid = cleaned.index(cleaned.startIndex, offsetBy: 4)
        return "\(cleaned[..<mid])-\(cleaned[mid...])"
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    static func findByDeviceCode(_ code: String, on db: Database) async throws -> DeviceAuthorization? {
        try await DeviceAuthorization.query(on: db)
            .filter(\.$deviceCodeHash == hashCode(code))
            .first()
    }
}

extension DeviceAuthorization: Content {}
