import Foundation
import Vapor

/// Ceilings for caller-supplied text and list fields, and the guards that apply
/// them (STR-195).
///
/// Every string a request can persist needs a ceiling. Before this one existed,
/// the ceiling was a habit rather than a rule: about a dozen fields had one,
/// hand-applied where somebody happened to think of it, and the fields that
/// went without were the core workload resources — every `name` and
/// `description` on VMs, volumes, sandboxes, images, projects, and the org
/// hierarchy. Nothing downstream stood in for the missing check: Fluent's
/// `.string` is Postgres `TEXT`, so a name was bounded only by Vapor's 16 MB
/// default body size.
///
/// Two ceilings cover the whole surface. Reach for one of them rather than a
/// new number — a third ceiling is how the first two stop meaning anything, and
/// the per-field numbers are exactly what produced the distribution above.
/// Fields with a grammar of their own (`LogicalNetwork.domainName`,
/// `VM.hostname`, cloud-init `userData`) keep it; a bound here is the floor
/// under everything else, not a replacement for a real parser.
enum Validate {

    // MARK: - Ceilings

    /// Names and other short single-line identifiers a caller types once and
    /// then refers to. 128 is the largest of the name-shaped bounds already
    /// applied by hand (`ServiceAccount.name` and `Site` label keys), so
    /// adopting it fleet-wide cannot make something that fits today stop
    /// fitting.
    static let nameLength = 128

    /// Free-form text: descriptions, notes, and structured-but-not-prose values
    /// of the same order of magnitude (an SSH public key, a sandbox env value).
    static let textLength = 4096

    // MARK: - Measurement

    /// The unit the bounds are counted in: Unicode scalars, which is what
    /// Postgres `character_length` counts — and therefore what the `CHECK`
    /// constraints backing these bounds count.
    ///
    /// Deliberately not `String.count`, which counts grapheme clusters: a
    /// string of 128 combining sequences passes a `.count` check and is then
    /// refused by the column constraint, turning a caller's `400` into a `500`.
    static func length(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    // MARK: - Strings

    /// A required name: trimmed of surrounding whitespace, non-empty, bounded.
    ///
    /// Returns the trimmed value, and deliberately isn't discardable — persist
    /// what comes back rather than what went in, or the trim silently doesn't
    /// happen.
    static func name(_ value: String, _ field: String = "name", max: Int = nameLength) throws -> String {
        try boundedName(value, field, max)
    }

    /// An optional name. Absent stays absent; present is held to `name(_:_:)`,
    /// so a caller cannot blank a name out by sending whitespace on an update.
    static func name(_ value: String?, _ field: String = "name", max: Int = nameLength) throws -> String? {
        guard let value else { return nil }
        return try boundedName(value, field, max)
    }

    /// The shared body of both `name` overloads. Separate so neither overload
    /// calls the other — a `String` argument is equally applicable to both, and
    /// the recursive call would be ambiguous.
    private static func boundedName(_ value: String, _ field: String, _ max: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "'\(field)' must not be empty")
        }
        guard length(trimmed) <= max else {
            throw Abort(.badRequest, reason: "'\(field)' must be \(max) characters or fewer")
        }
        return trimmed
    }

    /// Free-form text. Bounded only: empty is meaningful (it's how a
    /// description is cleared), and the value is stored exactly as sent, since
    /// trimming prose is not this function's call to make.
    @discardableResult
    static func text(_ value: String?, _ field: String = "description", max: Int = textLength) throws -> String? {
        guard let value else { return nil }
        guard length(value) <= max else {
            throw Abort(.badRequest, reason: "'\(field)' must be \(max) characters or fewer")
        }
        return value
    }

    // MARK: - Collections

    /// A cardinality bound for a list field. `max` is the caller's ceiling, not
    /// a hint: a list that exceeds it is a `400`, never a silent truncation.
    static func list<Element>(_ value: [Element]?, _ field: String, max: Int) throws {
        guard let value else { return }
        guard value.count <= max else {
            throw Abort(.badRequest, reason: "'\(field)' must have \(max) entries or fewer")
        }
    }

    /// A list of strings: bounded in cardinality and in the length of every
    /// element, since either dimension alone leaves the total unbounded.
    static func stringList(
        _ value: [String]?, _ field: String, maxEntries: Int, maxLength: Int = textLength
    ) throws {
        guard let value else { return }
        try list(value, field, max: maxEntries)
        for element in value where length(element) > maxLength {
            throw Abort(.badRequest, reason: "Each entry in '\(field)' must be \(maxLength) characters or fewer")
        }
    }

    /// A string-to-string map: bounded in entry count, key length, and value
    /// length. Same reasoning as `stringList` — three dimensions, all of them
    /// caller-controlled.
    static func stringMap(
        _ value: [String: String]?, _ field: String, maxEntries: Int,
        maxKeyLength: Int = nameLength, maxValueLength: Int = textLength
    ) throws {
        guard let value else { return }
        guard value.count <= maxEntries else {
            throw Abort(.badRequest, reason: "'\(field)' must have \(maxEntries) entries or fewer")
        }
        for (key, element) in value {
            guard length(key) <= maxKeyLength else {
                throw Abort(.badRequest, reason: "Keys in '\(field)' must be \(maxKeyLength) characters or fewer")
            }
            guard length(element) <= maxValueLength else {
                throw Abort(
                    .badRequest,
                    reason: "The value for '\(key)' in '\(field)' must be \(maxValueLength) characters or fewer")
            }
        }
    }

    // MARK: - SSH public keys

    /// Key types an `authorized_keys` entry may name. These are *key* types,
    /// not signature algorithms: an RSA key is `ssh-rsa` on this line even when
    /// it will be used with `rsa-sha2-512`, which is why those names are absent.
    private static let sshKeyTypes: Set<String> = [
        "ssh-ed25519",
        "ssh-rsa",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// An SSH public key in `authorized_keys` form: `<type> <base64 blob>
    /// [comment]`, one line, with the algorithm name inside the blob matching
    /// the one in front of it.
    ///
    /// Bounded *and* parsed, because this field is not stored for display: it
    /// is rendered into the guest's `authorized_keys` via cloud-init. The agent
    /// sanitizes at the sink (`CloudInitProvisioner.sshAuthorizedKeysBlock`
    /// strips control characters and escapes YAML metacharacters), but
    /// sanitizing means a two-line paste silently becomes one mangled key in
    /// the guest. Rejecting here turns that into an immediate `400`. Empty or
    /// whitespace-only input normalizes to nil — no key requested.
    static func sshPublicKey(_ value: String?, _ field: String = "sshPublicKey") throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard length(trimmed) <= textLength else {
            throw Abort(.badRequest, reason: "'\(field)' must be \(textLength) characters or fewer")
        }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw Abort(
                .badRequest,
                reason: "'\(field)' must be one line of printable characters: an authorized_keys "
                    + "entry holds exactly one key")
        }

        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            throw Abort(.badRequest, reason: "'\(field)' must look like '<type> <base64 key> [comment]'")
        }
        let type = String(fields[0])
        guard sshKeyTypes.contains(type) else {
            throw Abort(
                .badRequest,
                reason: "'\(field)' has unsupported key type '\(type)'; expected one of "
                    + sshKeyTypes.sorted().joined(separator: ", "))
        }
        guard let blob = Data(base64Encoded: String(fields[1])), embeddedSSHKeyType(blob) == type else {
            throw Abort(
                .badRequest,
                reason: "'\(field)' is not a valid \(type) key: the base64 blob must carry the same algorithm name")
        }
        return trimmed
    }

    /// The algorithm name an OpenSSH public-key blob opens with: a big-endian
    /// 32-bit length followed by that many bytes of ASCII. Returns nil for
    /// anything that isn't shaped like one.
    private static func embeddedSSHKeyType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let algorithmLength =
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard algorithmLength > 0, bytes.count >= 4 + algorithmLength else { return nil }
        return String(decoding: bytes[4..<(4 + algorithmLength)], as: UTF8.self)
    }
}

/// A request body that bounds and normalizes its own fields.
///
/// The rules live on the DTO rather than in the handler, so a resource's update
/// path cannot drift from its create path: both decode a type that already
/// knows what it will accept. `validate()` is `mutating` and
/// `decodeValidated(_:)` hands back the normalized value, so there is exactly
/// one pass — a handler reads `request.name` and gets the trimmed, bounded
/// string, with no second guard to keep in step.
protocol ValidatedRequestBody: Decodable {
    /// Throws `Abort(.badRequest)` describing the first field that doesn't fit,
    /// and writes back the normalized form of the fields that have one.
    mutating func validate() throws
}

extension ContentContainer {
    /// Decodes a request body, then bounds and normalizes it.
    func decodeValidated<Body: ValidatedRequestBody>(_ type: Body.Type) throws -> Body {
        var body = try decode(type)
        try body.validate()
        return body
    }
}
