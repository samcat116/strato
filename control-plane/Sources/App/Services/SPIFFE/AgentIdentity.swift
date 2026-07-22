import Foundation

/// An agent's cryptographic identity: the trust domain that vouches for it and
/// its name within that domain — exactly the two components of its SPIFFE ID,
/// `spiffe://<trustDomain>/agent/<name>`.
///
/// This is the key everything agent-scoped is stored under: the in-process
/// connection map, the Valkey presence and socket-route keys, and console/exec
/// session ownership. The bare name is **not** a key. With one trust domain the
/// distinction is invisible, but once each organization has its own domain
/// (issue #600) two orgs may each enroll `agent-1`, and a name-keyed map would
/// hand one org's socket the other's desired state.
///
/// The database mirrors the same pair: `agents` and `agent_enrollments` both
/// carry `trust_domain`, and their uniqueness is `(trust_domain, name)`.
struct AgentIdentity: Sendable, Hashable, CustomStringConvertible {
    let trustDomain: String
    let name: String

    init(trustDomain: String, name: String) {
        self.trustDomain = trustDomain
        self.name = name
    }

    /// Recover the identity from an agent SPIFFE ID. Returns nil for a
    /// non-agent path — nothing else may be used as an agent key.
    init?(key: String) {
        guard let spiffeID = SPIFFEIdentity(uri: key), let agentID = spiffeID.agentID, !agentID.isEmpty else {
            return nil
        }
        self.trustDomain = spiffeID.trustDomain
        self.name = agentID
    }

    /// The full SPIFFE ID, and the string form used as a map/registry key.
    var key: String {
        "spiffe://\(trustDomain)/agent/\(name)"
    }

    var description: String { key }
}

extension SPIFFEIdentity {
    /// This identity as an agent identity, or nil if it isn't an agent SVID.
    var agentIdentity: AgentIdentity? {
        guard let agentID, !agentID.isEmpty else { return nil }
        return AgentIdentity(trustDomain: trustDomain, name: agentID)
    }
}
