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
    @Test("Identity-plane actions are exempt from the node scope")
    func identityActionsExempt() throws {
        let user = IAMNode(type: .user, id: UUID())
        let r = try restriction(["*"], node: project)
        for action in IAMRoleRegistry.identityActions {
            #expect(r.permits(action: action, chain: [user]))
        }
        // Exempt from the node half only — not from the action half.
        let readOnly = try restriction(["user:read"], node: project)
        #expect(readOnly.permits(action: "user:read", chain: [user]))
        #expect(!readOnly.permits(action: "user:delete", chain: [user]))
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
        #expect(r.permits(action: "vm:read"))
        #expect(r.permits(action: "vm:list"))
        #expect(r.permits(action: "user:read"))
        #expect(r.permits(action: "image:download"))
        #expect(r.permits(action: "iam:readPolicy"))
        #expect(!r.permits(action: "vm:start"))
        #expect(!r.permits(action: "vm:delete"))
        #expect(!r.permits(action: "iam:setPolicy"))
        // The three tightenings STR-115 accepts: all reachable on a safe method
        // before, none of them a read.
        #expect(!r.permits(action: "sandbox:exec"))
        #expect(!r.permits(action: "vm:viewConsole"))
        #expect(!r.permits(action: "vm:exec"))
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

    @Test("readActions covers every read/list action the registry knows")
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
        // A service wildcard is only covered by `*` or the same wildcard —
        // enumerating today's `vm:` actions would stop covering tomorrow's.
        #expect(!issuer.covers(try restriction(["vm:*"])))
        #expect(try restriction(["vm:*"]).covers(try restriction(["vm:*"])))
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
