import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native IAM persistence", .serialized)
struct IAMPersistenceTests {
    @Test("policy-set changes commit immutable rows and one ledger entry")
    func policySetChange() async throws {
        try await withIAMDatabase { _, iam in
            let owner = IAMOwnerReference(type: "organization", id: UUID())
            let node = IAMNodeReference(type: "organization", id: owner.id)
            let actorID = UUID()
            let role = IAMRoleSnapshot(
                id: UUID(),
                name: "operator",
                description: "Operates workloads",
                ownerType: owner.type,
                ownerID: owner.id,
                cedarText: "permit(principal, action, resource);",
                actions: ["vm:read", "vm:start"],
                managed: false,
                createdBy: actorID
            )
            let policy = IAMPolicySnapshot(
                id: UUID(),
                name: "allow-operators",
                description: nil,
                ownerType: owner.type,
                ownerID: owner.id,
                cedarText: "permit(principal, action, resource);",
                effect: "permit",
                enabled: true,
                createdBy: actorID
            )
            let guardrail = IAMGuardrailSnapshot(
                id: UUID(),
                name: "protect-production",
                description: "Production safety ceiling",
                nodeType: node.type,
                nodeID: node.id,
                effect: "forbid",
                actions: ["vm:delete"],
                principalMatchKind: "any",
                principalMatchID: nil,
                resourceMatchKind: "environment",
                resourceMatchValue: "production",
                enabled: true,
                createdBy: actorID,
                cedarText: "forbid(principal, action, resource);",
                authored: false
            )

            let version = try await iam.withPolicySetChange { transaction in
                _ = try await transaction.createRole(role)
                _ = try await transaction.createPolicy(policy)
                _ = try await transaction.createGuardrail(guardrail)
                return try await transaction.bumpPolicySetVersion(
                    reason: "seed IAM policy set",
                    changedBy: actorID
                )
            }

            #expect(version == 1)
            #expect(try await iam.role(id: role.id)?.createdAt != nil)
            #expect(try await iam.roles(ownedBy: owner).map(\.id) == [role.id])
            #expect(try await iam.policy(id: policy.id)?.updatedAt != nil)
            #expect(try await iam.policies(ownedBy: owner).map(\.id) == [policy.id])
            #expect(try await iam.guardrail(id: guardrail.id)?.updatedAt != nil)
            #expect(try await iam.guardrails(attachedTo: node).map(\.id) == [guardrail.id])
            #expect(try await iam.currentPolicySetVersion() == 1)
            let latest = try #require(try await iam.latestPolicySetVersion())
            #expect(latest.version == 1)
            #expect(latest.reason == "seed IAM policy set")
            #expect(latest.changedBy == actorID)
            #expect(latest.createdAt != nil)
        }
    }

    @Test("a failed policy-set change rolls back rows and ledger together")
    func rollback() async throws {
        enum ExpectedFailure: Error { case stop }

        try await withIAMDatabase { _, iam in
            let owner = IAMOwnerReference(type: "project", id: UUID())
            let role = IAMRoleSnapshot(
                id: UUID(),
                name: "temporary",
                description: nil,
                ownerType: owner.type,
                ownerID: owner.id,
                cedarText: "",
                actions: [],
                managed: false,
                createdBy: nil
            )

            do {
                try await iam.withPolicySetChange { transaction in
                    _ = try await transaction.createRole(role)
                    _ = try await transaction.bumpPolicySetVersion(reason: "must roll back")
                    throw ExpectedFailure.stop
                }
                Issue.record("Expected policy-set transaction to fail")
            } catch ExpectedFailure.stop {}

            #expect(try await iam.role(id: role.id) == nil)
            #expect(try await iam.currentPolicySetVersion() == 0)
        }
    }

    @Test("role binding intent preserves active filtering and exact revocation")
    func roleBindings() async throws {
        try await withIAMDatabase { _, iam in
            let subject = IAMOwnerReference(type: "user", id: UUID())
            let node = IAMNodeReference(type: "project", id: UUID())
            let roleID = UUID()
            let active = IAMRoleBindingSnapshot(
                principalType: subject.type,
                principalID: subject.id,
                roleID: roleID,
                nodeType: node.type,
                nodeID: node.id,
                condition: "context.mfa == true",
                createdBy: UUID()
            )
            let expired = IAMRoleBindingSnapshot(
                principalType: subject.type,
                principalID: subject.id,
                roleID: UUID(),
                nodeType: node.type,
                nodeID: node.id,
                expiresAt: Date(timeIntervalSince1970: 1)
            )

            let created = try await iam.grant(active)
            _ = try await iam.grant(expired)
            #expect(created.createdAt != nil)
            #expect(try await iam.activeBindings(subject: subject, node: node).map(\.id) == [active.id])
            #expect(try await iam.bindings(at: [node]).map(\.id) == [active.id])
            #expect(try await iam.activeBindingCount(roleID: roleID) == 1)

            do {
                _ = try await iam.grant(
                    IAMRoleBindingSnapshot(
                        principalType: subject.type,
                        principalID: subject.id,
                        roleID: roleID,
                        nodeType: node.type,
                        nodeID: node.id
                    )
                )
                Issue.record("Expected duplicate binding to fail")
            } catch let error as IAMPersistenceError {
                #expect(error == .duplicateBinding)
            }

            #expect(try await iam.revoke(subject: subject, roleID: roleID, node: node) == [active.id])
            #expect(try await iam.activeBindings(subject: subject, node: node).isEmpty)
            #expect(Set(try await iam.revokeAll(atNodes: [node])) == [expired.id])
        }
    }

    @Test("concurrent policy writes allocate distinct versions")
    func concurrentVersions() async throws {
        try await withIAMDatabase(maximumConnections: 2) { _, iam in
            let versions = try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<2 {
                    group.addTask {
                        try await iam.withPolicySetChange { transaction in
                            try await transaction.bumpPolicySetVersion(reason: "change \(index)")
                        }
                    }
                }
                var result: [Int] = []
                for try await version in group { result.append(version) }
                return result
            }

            #expect(Set(versions) == [1, 2])
            #expect(try await iam.currentPolicySetVersion() == 2)
        }
    }

    private func withIAMDatabase(
        maximumConnections: Int = 1,
        _ test: (PostgresDatabase, IAMPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(maximumConnections: maximumConnections) { database in
            try await database.withSession(operation: "test.iam.schema") { session in
                _ = try await session.command(iamRoleSchema, operation: "test.iam.schema.roles")
                _ = try await session.command(iamPolicySchema, operation: "test.iam.schema.policies")
                _ = try await session.command(iamGuardrailSchema, operation: "test.iam.schema.guardrails")
                _ = try await session.command(iamBindingSchema, operation: "test.iam.schema.bindings")
                _ = try await session.command(iamVersionSchema, operation: "test.iam.schema.versions")
            }
            try await test(database, ControlPlanePersistence(database: database).iam)
        }
    }
}

private let iamRoleSchema = """
    CREATE TABLE iam_roles (
        id UUID PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        owner_type TEXT NOT NULL,
        owner_id UUID NOT NULL,
        cedar_text TEXT NOT NULL,
        actions TEXT[] NOT NULL,
        managed BOOLEAN NOT NULL,
        created_by UUID,
        created_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ,
        CONSTRAINT "uq:iam_roles.owner_type+iam_roles.owner_id+iam_roles.name"
            UNIQUE (owner_type, owner_id, name)
    )
    """

private let iamPolicySchema = """
    CREATE TABLE iam_policies (
        id UUID PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        owner_type TEXT NOT NULL,
        owner_id UUID NOT NULL,
        cedar_text TEXT NOT NULL,
        effect TEXT NOT NULL,
        enabled BOOLEAN NOT NULL,
        created_by UUID,
        created_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ,
        CONSTRAINT "uq:iam_policies.owner_type+iam_policies.owner_id+iam_policies.n"
            UNIQUE (owner_type, owner_id, name)
    )
    """

private let iamGuardrailSchema = """
    CREATE TABLE iam_guardrails (
        id UUID PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        node_type TEXT NOT NULL,
        node_id UUID NOT NULL,
        effect TEXT NOT NULL CHECK (effect = 'forbid'),
        actions TEXT[] NOT NULL,
        principal_match_kind TEXT NOT NULL,
        principal_match_id UUID,
        resource_match_kind TEXT NOT NULL,
        resource_match_value TEXT,
        enabled BOOLEAN NOT NULL,
        created_by UUID,
        created_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ,
        cedar_text TEXT,
        authored BOOLEAN NOT NULL DEFAULT FALSE,
        CONSTRAINT "uq:iam_guardrails.node_type+iam_guardrails.node_id+iam_guardrai"
            UNIQUE (node_type, node_id, name)
    )
    """

private let iamBindingSchema = """
    CREATE TABLE role_bindings (
        id UUID PRIMARY KEY,
        principal_type TEXT NOT NULL,
        principal_id UUID NOT NULL,
        role_id UUID NOT NULL,
        node_type TEXT NOT NULL,
        node_id UUID NOT NULL,
        condition TEXT,
        expires_at TIMESTAMPTZ,
        created_by UUID,
        created_at TIMESTAMPTZ,
        CONSTRAINT uq_role_bindings_principal_role_node
            UNIQUE (principal_type, principal_id, role_id, node_type, node_id)
    )
    """

private let iamVersionSchema = """
    CREATE TABLE iam_policy_set_versions (
        id UUID PRIMARY KEY,
        version BIGINT NOT NULL,
        reason TEXT NOT NULL,
        changed_by UUID,
        created_at TIMESTAMPTZ,
        CONSTRAINT "uq:iam_policy_set_versions.version" UNIQUE (version)
    )
    """
