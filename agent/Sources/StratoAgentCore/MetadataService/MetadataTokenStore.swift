import Crypto
import Foundation

/// The IMDSv2 sessions one listener has minted (STR-56).
///
/// ## What a token is bound to
///
/// A session belongs to the instance it was minted for. Presented by anyone
/// else it is refused, even though that other caller is itself perfectly
/// legitimate. That is what makes "ingress port A cannot read VM B's metadata"
/// hold under a *stolen* credential rather than only under a well-behaved guest:
/// exfiltrating A's token from A buys nothing, because the identity is re-derived
/// from the source address on every request and the token has to agree with it.
///
/// The binding is to the VM, not to the address, so an instance whose address
/// changes mid-lease keeps its session — the identity is the instance, and the
/// address is only how the listener recognizes it.
///
/// ## Why there is no constant-time compare here
///
/// Sessions are keyed by `SHA256(token)`, so no secret is ever compared against
/// attacker-supplied input: the lookup is a dictionary hit on a digest of a
/// value the caller already knows. The repo has no constant-time comparison
/// helper (`docs/development/code-review.md` notwithstanding, nothing needs one
/// yet) and this does not add the requirement for one — a design that never
/// compares secrets beats a helper that compares them carefully. It also means a
/// heap dump of the agent yields digests rather than bearer tokens.
///
/// ## Time
///
/// Expiry is on `ContinuousClock`, passed in rather than read here: tests
/// express expiry as arithmetic instead of sleeping, and a wall-clock step (NTP,
/// a suspended host) can neither extend a session nor void every session at
/// once.
public actor MetadataTokenStore {
    private struct Session {
        let vmId: UUID
        let expiresAt: ContinuousClock.Instant
    }

    /// Keyed by the token's digest — never by the token.
    private var sessions: [String: Session] = [:]
    private let randomToken: @Sendable () -> String

    public init(randomToken: @escaping @Sendable () -> String = MetadataTokenStore.defaultRandomToken) {
        self.randomToken = randomToken
    }

    /// Mints a session for `vmId` and returns the opaque bearer string. Only its
    /// digest is retained, so this is the one moment the token exists in the
    /// agent's memory as itself.
    public func mint(for vmId: UUID, ttlSeconds: Int, at now: ContinuousClock.Instant) -> String {
        sweep(now: now)
        enforceCap(for: vmId)
        let token = randomToken()
        sessions[Self.digest(token)] = Session(vmId: vmId, expiresAt: now.advanced(by: .seconds(ttlSeconds)))
        return token
    }

    /// True only when `token` was minted for `vmId` and has not expired.
    public func isValid(_ token: String, for vmId: UUID, at now: ContinuousClock.Instant) -> Bool {
        guard let session = sessions[Self.digest(token)] else { return false }
        guard session.expiresAt > now else { return false }
        return session.vmId == vmId
    }

    /// Drops every session belonging to an instance this listener no longer
    /// serves.
    ///
    /// Called whenever a snapshot lands, because an address outlives the VM it
    /// was allocated to — the same reason `MetadataStore` seals a withdrawal
    /// rather than forgetting it. Without this, a token minted by a deleted VM
    /// would stay valid for as long as its TTL, and the next holder of that
    /// address would be the one presenting it.
    public func retain(servable: Set<UUID>) {
        sessions = sessions.filter { servable.contains($0.value.vmId) }
    }

    /// Live session count, for tests and diagnostics. Never exposes a token.
    public func liveTokenCount() -> Int { sessions.count }

    // MARK: - Bounds

    /// Expired sessions cost memory until something notices; minting is the
    /// natural moment, so there is no timer task to supervise.
    private func sweep(now: ContinuousClock.Instant) {
        sessions = sessions.filter { $0.value.expiresAt > now }
    }

    /// A guest can mint in a loop, and every session it mints lives in the
    /// agent's address space. Past the cap the soonest-expiring session for that
    /// VM is dropped, so a loop costs a bounded amount and a well-behaved
    /// guest's newest token is never the one evicted.
    private func enforceCap(for vmId: UUID) {
        let owned = sessions.filter { $0.value.vmId == vmId }
        guard owned.count >= MetadataLimits.maxTokensPerVM else { return }
        let evictions = owned.sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(owned.count - MetadataLimits.maxTokensPerVM + 1)
        for eviction in evictions { sessions.removeValue(forKey: eviction.key) }
    }

    // MARK: - Minting

    /// 256 bits of CSPRNG output, base64 with the non-alphanumeric characters
    /// dropped so the token is safe in a header value with no escaping. The
    /// repo's established idiom (`APIKey.generateAPIKey`, `SCIMToken`).
    public static func defaultRandomToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        return String(encoded.filter { $0 != "+" && $0 != "/" && $0 != "=" })
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
