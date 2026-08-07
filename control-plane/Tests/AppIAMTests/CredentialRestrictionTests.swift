import Foundation
import Testing

@testable import App

/// STR-115: the restriction value itself — what it permits, and what the legacy
/// scope shim resolves an existing credential to.
///
/// These are pure: no database, no Cedar. The Cedar half (that a restriction
/// actually denies) is `CredentialRestrictionPolicyTests`.
@Suite("Credential Restriction")
struct CredentialRestrictionTests {

    private let project = IAMNode(type: .project, id: UUID())
    private let otherProject = IAMNode(type: .project, id: UUID())

    private func restriction(_ actions: [String], node: IAMNode? = nil) throws -> CredentialRestriction {
        try CredentialRestriction.validated(
            actions: actions, nodeType: node?.type.rawValue, nodeID: node?.id)
    }

    // MARK: - The action half

    @Test("An exact action permits itself and nothing else")
    func exactAction() throws {
        let r = try restriction(["vm:read"])
        #expect(r.permits(action: "vm:read"))
        #expect(!r.permits(action: "vm:list"))
        #expect(!r.permits(action: "vm:delete"))
        #expect(!r.permits(action: "volume:read"))
    }

    @Test("A service wildcard covers its whole service, including actions shipped later")
    func serviceWildcard() throws {
        let r = try restriction(["vm:*"])
        for action in IAMRoleRegistry.allActions where action.hasPrefix("vm:") {
            #expect(r.permits(action: action), "vm:* did not cover \(action)")
        }
        #expect(!r.permits(action: "volume:read"))
        // The pattern is a prefix match, not an enumeration, so an action that
        // does not exist yet is covered too — the property `vm:*` is written
        // for.
        #expect(r.permits(action: "vm:teleport"))
    }

    @Test("The universal wildcard is the unrestricted credential")
    func universalWildcard() throws {
        #expect(try restriction(["*"]) == .unrestricted)
        #expect(CredentialRestriction.unrestricted.isUnrestricted)
        for action in IAMRoleRegistry.allActions {
            #expect(CredentialRestriction.unrestricted.permits(action: action))
        }
    }

    /// The trap `CredentialRestriction` exists to avoid: `GuardrailActions`
    /// reads an empty pattern list as "every action", because an empty *ceiling*
    /// is the broadest one. An empty *restriction* must be the narrowest.
    @Test("An empty action list permits nothing, and cannot be created through the API")
    func emptyPermitsNothing() {
        for action in IAMRoleRegistry.allActions {
            #expect(!CredentialRestriction.denyAll.permits(action: action))
        }
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: [], nodeType: nil, nodeID: nil)
        }
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["  "], nodeType: nil, nodeID: nil)
        }
    }

    @Test("An unknown action or service is rejected at write time")
    func unknownActionRejected() {
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["vm:teleport"], nodeType: nil, nodeID: nil)
        }
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["teleport:*"], nodeType: nil, nodeID: nil)
        }
    }

    // MARK: - The node half

    @Test("A node scope permits only resources in its subtree")
    func nodeScope() throws {
        let vm = IAMNode(type: .virtualMachine, id: UUID())
        let r = try restriction(["vm:*"], node: project)

        #expect(r.permits(action: "vm:read", chain: [vm, project, IAMNode(type: .organization, id: UUID())]))
        #expect(!r.permits(action: "vm:read", chain: [vm, otherProject, IAMNode(type: .organization, id: UUID())]))
        // The scope node itself is in scope.
        #expect(r.permits(action: "vm:read", chain: [project]))
    }

    @Test("The action half still applies inside the node scope")
    func nodeScopeDoesNotWidenActions() throws {
        let vm = IAMNode(type: .virtualMachine, id: UUID())
        let r = try restriction(["vm:read"], node: project)
        #expect(r.permits(action: "vm:read", chain: [vm, project]))
        #expect(!r.permits(action: "vm:delete", chain: [vm, project]))
    }

    /// A user record is parentless, so its chain can never contain a project.
    /// Without the exemption a project-scoped token could not read its own
    /// user record and `strato whoami` would break.
    @Test("Identity-plane reads are exempt from the node scope")
    func identityReadsExempt() throws {
        let user = IAMNode(type: .user, id: UUID())
        let r = try restriction(["*"], node: project)
        for action in IAMRoleRegistry.identityReadActions {
            #expect(r.permits(action: action, chain: [user]))
        }
        // Exempt from the node half only — not from the action half.
        let readOnly = try restriction(["user:read"], node: project)
        #expect(readOnly.permits(action: "user:read", chain: [user]))
        #expect(!readOnly.permits(action: "user:delete", chain: [user]))
    }

    /// The escalation the exemption must not open: a user record is parentless
    /// for `user:delete` exactly as it is for `user:read`, so an exemption that
    /// covered both would let a token issued for one project delete any user in
    /// the deployment — the one global surface a scoped credential could still
    /// reach.
    @Test("Identity-plane mutations still obey the node scope")
    func identityMutationsBoundByNodeScope() throws {
        let user = IAMNode(type: .user, id: UUID())
        let r = try restriction(["*"], node: project)
        #expect(r.permits(action: "user:read", chain: [user]))
        #expect(!r.permits(action: "user:update", chain: [user]))
        #expect(!r.permits(action: "user:delete", chain: [user]))
        #expect(IAMRoleRegistry.identityReadActions == ["user:read"])
    }

    @Test("A node scope needs both a type and an id, and a known type")
    func nodeScopeValidation() {
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["*"], nodeType: "project", nodeID: nil)
        }
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["*"], nodeType: nil, nodeID: UUID())
        }
        #expect(throws: (any Error).self) {
            _ = try CredentialRestriction.validated(actions: ["*"], nodeType: "spaceship", nodeID: UUID())
        }
    }

    // MARK: - The legacy scope shim

    @Test("write and admin both resolve to unrestricted, as they always effectively were")
    func writeAndAdminAreUnrestricted() {
        #expect(CredentialRestriction(legacyScopes: ["write"]).isUnrestricted)
        #expect(CredentialRestriction(legacyScopes: ["admin"]).isUnrestricted)
        #expect(CredentialRestriction(legacyScopes: ["read", "write"]).isUnrestricted)
    }

    @Test("read resolves to every action whose name says it reads")
    func readResolvesToReadActions() {
        let r = CredentialRestriction(legacyScopes: ["read"])
        #expect(!r.isUnrestricted)
        // The legacy shim and a key minted read-only through the API are the
        // same value, so the two spellings cannot diverge.
        #expect(r == .readOnly)
        #expect(r.permits(action: "vm:read"))
        #expect(r.permits(action: "vm:list"))
        #expect(r.permits(action: "user:read"))
        #expect(r.permits(action: "image:download"))
        #expect(r.permits(action: "iam:readPolicy"))
        #expect(!r.permits(action: "vm:start"))
        #expect(!r.permits(action: "vm:delete"))
        #expect(!r.permits(action: "iam:setPolicy"))
        // The tightenings STR-115 accepts: all reachable on a safe method
        // before, none of them a read. `agent:manage` is the fourth — it gates
        // the *read* of the enrollment list, so a read credential now sees an
        // empty page there.
        #expect(!r.permits(action: "sandbox:exec"))
        #expect(!r.permits(action: "vm:viewConsole"))
        #expect(!r.permits(action: "vm:exec"))
        #expect(!r.permits(action: "agent:manage"))
    }

    /// The `read` pattern is resolved on every check, never expanded into the
    /// stored row — otherwise a key minted read-only today would 403 on an
    /// action added next release while a legacy `read`-scoped key picked it up.
    @Test("The read pattern stays symbolic and resolves against the live action set")
    func readPatternIsSymbolic() throws {
        let r = try restriction(["read"])
        #expect(r.actions == ["read"])
        for action in IAMRoleRegistry.readActions {
            #expect(r.permits(action: action), "read did not cover \(action)")
        }
        #expect(!r.permits(action: "vm:start"))
        // Nothing is literally named `read`, so the pattern cannot collide with
        // an action.
        #expect(!IAMRoleRegistry.allActions.contains("read"))
    }

    @Test("The read pattern composes with concrete actions and with a node scope")
    func readPatternComposes() throws {
        let mixed = try restriction(["read", "vm:start"])
        #expect(mixed.actions == ["read", "vm:start"])
        #expect(mixed.permits(action: "volume:read"))
        #expect(mixed.permits(action: "vm:start"))
        #expect(!mixed.permits(action: "vm:delete"))

        // `*` absorbs everything, including the symbolic pattern.
        #expect(try restriction(["read", "*"]) == .unrestricted)

        let scoped = try restriction(["read"], node: project)
        let vm = IAMNode(type: .virtualMachine, id: UUID())
        #expect(scoped.permits(action: "vm:read", chain: [vm, project]))
        #expect(!scoped.permits(action: "vm:read", chain: [vm, otherProject]))
    }

    /// A credential whose scopes hold nothing recognizable is dead today —
    /// `grants(_:)` answered false for every scope, so even a GET was a 403.
    /// The shim must not resurrect it.
    @Test("A credential with no recognizable scope permits nothing")
    func unrecognizedScopesPermitNothing() {
        for scopes in [[], ["bogus"], ["Read"], ["", " "]] {
            let r = CredentialRestriction(legacyScopes: scopes)
            #expect(r == .denyAll, "\(scopes) resolved to \(r.actions)")
            #expect(!r.permits(action: "vm:read"))
        }
    }

    @Test("Registry read actions cover every read/list action the registry knows")
    func readActionsIsDerivedNotCurated() {
        for action in IAMRoleRegistry.allActions where action.hasSuffix(":read") || action.hasSuffix(":list") {
            #expect(IAMRoleRegistry.readActions.contains(action), "\(action) missing from readActions")
        }
        for action in IAMRoleRegistry.readActions {
            #expect(IAMRoleRegistry.allActions.contains(action), "\(action) is not a real action")
        }
    }

    // MARK: - Minting a narrower credential

    @Test("An unrestricted credential may mint anything")
    func unrestrictedCovers() throws {
        #expect(CredentialRestriction.unrestricted.covers(try restriction(["vm:read"])))
        #expect(CredentialRestriction.unrestricted.covers(try restriction(["*"], node: project)))
        #expect(CredentialRestriction.unrestricted.covers(.denyAll))
    }

    @Test("A restricted credential may only mint within itself")
    func restrictedCoversOnlyNarrower() throws {
        let issuer = try restriction(["vm:read", "vm:list"])
        #expect(issuer.covers(try restriction(["vm:read"])))
        #expect(!issuer.covers(try restriction(["vm:delete"])))
        #expect(!issuer.covers(.unrestricted))
        // An open-ended pattern is only covered by `*` or by itself —
        // enumerating today's members would stop covering tomorrow's.
        #expect(!issuer.covers(try restriction(["vm:*"])))
        #expect(try restriction(["vm:*"]).covers(try restriction(["vm:*"])))
        #expect(!issuer.covers(.readOnly))
        #expect(CredentialRestriction.readOnly.covers(.readOnly))
        #expect(CredentialRestriction.readOnly.covers(try restriction(["vm:read"])))
        #expect(!CredentialRestriction.readOnly.covers(try restriction(["vm:start"])))
    }

    @Test("A node-scoped credential may not mint one scoped elsewhere or nowhere")
    func nodeScopedCoverage() throws {
        let issuer = try restriction(["*"], node: project)
        #expect(issuer.covers(try restriction(["vm:read"], node: project)))
        #expect(!issuer.covers(try restriction(["vm:read"], node: otherProject)))
        #expect(!issuer.covers(try restriction(["vm:read"])))
    }

    // MARK: - Storage round-trip

    @Test("Stored columns win over the legacy scopes; nil columns fall back to them")
    func storageRoundTrip() throws {
        let key = APIKey(
            userID: UUID(), name: "k", keyHash: "h", keyPrefix: "p", scopes: ["read"])
        #expect(key.restriction == CredentialRestriction(legacyScopes: ["read"]))

        let scoped = try restriction(["vm:read"], node: project)
        key.store(restriction: scoped)
        #expect(key.restrictionActions == ["vm:read"])
        #expect(key.restrictionNodeType == "project")
        #expect(key.restrictionNodeID == project.id)
        #expect(key.restriction == scoped)

        key.store(restriction: nil)
        #expect(key.restrictionActions == nil)
        #expect(key.restriction == CredentialRestriction(legacyScopes: ["read"]))
    }
}
