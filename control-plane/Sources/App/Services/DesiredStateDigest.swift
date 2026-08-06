import Crypto
import Foundation
import StratoShared

/// The ETag the desired-state long-poll serves (ADR 0001 stage 10): a
/// SHA-256 over the assembled sync with its per-assembly noise normalized out.
///
/// ADR 0001 originally proposed reusing `AgentService.desiredStateRevisions`
/// as the ETag. That counter is per-process and starts at zero on every
/// replica, so a poll that lands on a replica other than the one that served
/// the previous poll either collides (a wrong `304`, which strands the agent —
/// exactly the failure the ADR's "versions are never load-bearing" rule exists
/// to prevent) or misses on every request (a full `200` per poll, so the agent
/// re-polls immediately and the fleet degenerates into a continuous assembly
/// loop). A digest of the payload is replica-independent, so neither happens.
///
/// It also has no missed-bump failure mode at all. A counter has to be bumped
/// by hand at every mutation site across the sync's wide assembly scope — own
/// VMs, volumes, site-peer networks, security-group closures, floating IPs,
/// rollout targets — and a forgotten bump silently strands an agent. A digest
/// is derived from the bytes actually assembled, so there is nothing to forget.
///
/// The digest is still only ever a bandwidth optimization. The agent's
/// unconditional periodic re-fetch (`DesiredStatePoller`) is the correctness
/// invariant, and a digest that is wrong in the *conservative* direction —
/// different bytes for identical state — costs one extra full payload and
/// nothing else.
enum DesiredStateDigest {
    /// JSON pointers into an encoded `DesiredStateMessage` whose values vary
    /// per assembly without the desired state having changed. Each is pruned
    /// before hashing; `*` matches every element of an array.
    ///
    /// The list is deliberately a *subtraction* from the full payload rather
    /// than a hand-built projection of the fields that matter. A field added to
    /// the wire protocol tomorrow participates in the digest automatically, so
    /// forgetting to update this file produces a spurious `200` (harmless) and
    /// never a wrong `304` (an agent stranded until its next unconditional
    /// fetch).
    private static let volatilePaths: [[String]] = [
        // Correlation ids and the assembly timestamp. Fresh UUIDs and a fresh
        // `Date()` on every call: without pruning these, no two assemblies of
        // the same state ever agree and the ETag never hits.
        ["requestId"],
        ["syncId"],
        ["timestamp"],
        // Registry pull material. `sandboxRegistryMaterial` mints a fresh
        // bearer token whenever the cached one is near expiry, which is a
        // change in credential *material*, not in desired state. The
        // credential's identity (registry/username/bearer) stays in the digest,
        // so pointing a sandbox at a different registry or rotating the pull
        // secret's username still reads as a change.
        //
        // The risk this trades against is a credential expiring while the agent
        // is parked and never being refreshed. It doesn't bite: a sandbox
        // create or image change is itself a state change, so it delivers a
        // `200` carrying a fresh credential, and the parked case is precisely
        // the case where the agent has nothing to pull. The unconditional
        // re-fetch is the backstop for everything else.
        ["sandboxes", "*", "registryCredential", "password"],
        ["sandboxes", "*", "registryCredential", "expiresAt"],
        // The agent-update artifact link is re-resolved on every assembly and
        // may be presigned (`desiredAgentUpdateForSync`), so it churns on its
        // own. `sha256` stays and pins the artifact's identity far better than
        // a URL would, and `targetVersion` stays, so a real retarget is still a
        // change.
        ["desiredAgentUpdate", "artifactURL"],
    ]

    /// The ETag for `message`, as an opaque quoted token. Agents never compute
    /// or parse it — they echo it back in `If-None-Match`.
    static func etag(for message: DesiredStateMessage) throws -> String {
        "\"\(try digest(of: message))\""
    }

    /// The bare hex digest, without ETag quoting. Exposed for tests.
    static func digest(of message: DesiredStateMessage) throws -> String {
        let encoded = try WireProtocol.makeEncoder().encode(message)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw DigestError.notAnObject
        }
        for path in volatilePaths {
            object = prune(path, from: object)
        }
        // `.sortedKeys` is what makes the re-serialization canonical: the
        // dictionary that came out of `JSONSerialization` has no meaningful
        // key order of its own, so hashing it unsorted would produce a
        // different digest per process (or per insertion history).
        let canonical = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    enum DigestError: Error {
        case notAnObject
    }

    private static func prune(_ path: [String], from object: [String: Any]) -> [String: Any] {
        guard let head = path.first else { return object }
        var object = object
        let tail = Array(path.dropFirst())

        if tail.isEmpty {
            object.removeValue(forKey: head)
            return object
        }
        guard let value = object[head] else { return object }

        if tail.first == "*" {
            guard let array = value as? [Any] else { return object }
            let remainder = Array(tail.dropFirst())
            object[head] = array.map { element -> Any in
                guard let element = element as? [String: Any] else { return element }
                return prune(remainder, from: element)
            }
            return object
        }

        guard let child = value as? [String: Any] else { return object }
        object[head] = prune(tail, from: child)
        return object
    }
}
