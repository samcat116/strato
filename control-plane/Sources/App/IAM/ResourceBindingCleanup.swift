import Fluent
import Foundation

/// Drops the role bindings of a resource whose row is being removed.
///
/// `role_bindings` deliberately carries no foreign key to the node it protects
/// (an operation row has to be able to outlive its resource, and bindings sit
/// in the same "no FK to the resource" boat), so nothing reclaims a binding
/// whose node is gone: every delete path owns that cleanup itself, and a path
/// that forgets leaks the row permanently (STR-112).
///
/// VMs and sandboxes get a helper rather than a bare
/// `RoleBindingService.revokeAll(nodeType:nodeID:)` at the call site for two
/// reasons. Each has two removal sites — the agent-confirmed one in
/// `ObservedStateApplier` and the direct one in its controller, for an unplaced
/// resource or an offline agent — and each takes child nodes with it:
/// `vm_snapshots` / `sandbox_snapshots` cascade on their parent's foreign key,
/// so their bindings are orphaned by the same delete that orphans the parent's.
///
/// Containers are the same problem one level up (STR-137): deleting a project
/// cascades its images, networks, security groups, floating IPs, DNS zones (and
/// their records), volumes (and their snapshots) and service accounts, each of
/// which revokes correctly on its *own* delete endpoint and not at all on this
/// path. Folders and organizations then cascade projects.
enum ResourceBindingCleanup {
    /// The node types whose rows cascade away with a parent's, keyed by the
    /// parent. Declared rather than inferred so the tests can hold it against
    /// the schema: `ResourceBindingCleanupTests` walks the real `ON DELETE
    /// CASCADE` foreign keys into each parent table — transitively, the way
    /// Postgres cascades — and fails if one arrives that names an IAM node type
    /// absent from here. A new cascading child that is a bindable node would
    /// otherwise compile, pass, and silently leak — the exact failure this type
    /// exists to fix.
    ///
    /// Entries name only the *direct* children; a parent inherits its
    /// children's entries, so `.project` covers `.dnsRecord` (which cascades
    /// off `dns_zones`, not off `projects`) through `.dnsZone`, and the two
    /// containers cover everything a project does through `.project`.
    static let cascadingChildren: [IAMNodeType: [IAMNodeType]] = [
        .virtualMachine: [.vmSnapshot],
        .sandbox: [.sandboxSnapshot],
        .project: [
            .image, .network, .securityGroup, .floatingIP, .dnsZone, .volume, .volumeSnapshot,
            .serviceAccount,
        ],
        .dnsZone: [.dnsRecord],
        // A folder cascades its subtree: nested folders, and the projects of
        // every folder in it. Both are refused by a pre-check on the delete
        // endpoint, but the check and the delete are not one atomic step and
        // the foreign keys are CASCADE, not RESTRICT — unlike `vms.project_id`
        // (STR-98) — so a row created in the gap really does cascade away.
        .organizationalUnit: [.organizationalUnit, .project],
        .organization: [.organizationalUnit, .project],
    ]

    /// Revoke every binding on a VM node and on the checkpoints that cascade
    /// away with it. Call inside the transaction that removes the VM row, so
    /// bindings and rows can never diverge — and *before* the delete, which
    /// takes the `vm_snapshots` rows this reads with it.
    static func revokeBindings(forDeletedVM vmID: UUID, on db: any Database) async throws {
        let snapshotIDs = try await VMSnapshot.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .vmSnapshot, nodeIDs: snapshotIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .virtualMachine, nodeID: vmID, on: db)
    }

    /// Sandbox counterpart: the sandbox node plus the snapshots that cascade
    /// away with it (issue #428). Same read-before-delete ordering requirement.
    static func revokeBindings(forDeletedSandbox sandboxID: UUID, on db: any Database) async throws {
        let snapshotIDs = try await SandboxSnapshot.query(on: db)
            .filter(\.$sandbox.$id == sandboxID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .sandboxSnapshot, nodeIDs: snapshotIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .sandbox, nodeID: sandboxID, on: db)
    }

    /// Revoke every binding on a DNS zone node and on the authored records that
    /// cascade away with it. Records hang off the zone, not the project, so
    /// this is the one project child collected through its own parent rather
    /// than through `project_id`.
    static func revokeBindings(forDeletedDNSZone zoneID: UUID, on db: any Database) async throws {
        try await revokeBindings(forDeletedDNSZones: [zoneID], on: db)
    }

    static func revokeBindings(forDeletedDNSZones zoneIDs: [UUID], on db: any Database) async throws {
        guard !zoneIDs.isEmpty else { return }
        let recordIDs = try await DNSRecord.query(on: db)
            .filter(\.$zone.$id ~~ zoneIDs)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .dnsRecord, nodeIDs: recordIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .dnsZone, nodeIDs: zoneIDs, on: db)
    }

    /// Revoke every binding on a project node and on the resources that cascade
    /// away with the project row (STR-137).
    ///
    /// Same ordering requirement as the VM and sandbox helpers, and a stricter
    /// one: this reads the child rows the delete is about to remove, so it must
    /// run *before* `project.delete`, inside that transaction.
    static func revokeBindings(forDeletedProject projectID: UUID, on db: any Database) async throws {
        try await revokeBindings(forDeletedProjects: [projectID], on: db)
    }

    /// The plural form, for the container deletes that cascade a whole set of
    /// projects at once.
    static func revokeBindings(forDeletedProjects projectIDs: [UUID], on db: any Database) async throws {
        guard !projectIDs.isEmpty else { return }

        // A service account is both a node and a principal, so it needs both
        // directions: its own node bindings (at least its creator's) and the
        // bindings it holds elsewhere, which are not confined to this project
        // or even this organization (issue #491).
        let serviceAccountIDs = try await ServiceAccount.query(on: db)
            .filter(\.$project.$id ~~ projectIDs)
            .all(\.$id)
        for accountID in serviceAccountIDs {
            try await RoleBindingService.revokeAll(principalType: .serviceAccount, principalID: accountID, on: db)
        }
        try await RoleBindingService.revokeAll(nodeType: .serviceAccount, nodeIDs: serviceAccountIDs, on: db)

        let zoneIDs = try await DNSZone.query(on: db)
            .filter(\.$project.$id ~~ projectIDs)
            .all(\.$id)
        try await revokeBindings(forDeletedDNSZones: zoneIDs, on: db)

        let imageIDs = try await Image.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .image, nodeIDs: imageIDs, on: db)

        let networkIDs = try await LogicalNetwork.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .network, nodeIDs: networkIDs, on: db)

        let securityGroupIDs = try await SecurityGroup.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .securityGroup, nodeIDs: securityGroupIDs, on: db)

        let floatingIPIDs = try await FloatingIP.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .floatingIP, nodeIDs: floatingIPIDs, on: db)

        // `volume_snapshots` carries its own (denormalized) `project_id`, so it
        // cascades directly rather than through its volume.
        let snapshotIDs = try await VolumeSnapshot.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .volumeSnapshot, nodeIDs: snapshotIDs, on: db)

        let volumeIDs = try await Volume.query(on: db).filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .volume, nodeIDs: volumeIDs, on: db)

        try await RoleBindingService.revokeAll(nodeType: .project, nodeIDs: projectIDs, on: db)
    }

    /// Revoke every binding on a folder node and on the subtree that cascades
    /// away with it: nested folders, and the projects of every folder in the
    /// subtree with everything each of those projects carries.
    ///
    /// The delete endpoint refuses a folder that still has child folders or
    /// projects, so in practice there is nothing here to sweep; the subtree
    /// walk is what makes the answer right anyway when a row lands between the
    /// check and the delete, which read-committed Postgres allows and the
    /// CASCADE foreign key then honours.
    static func revokeBindings(forDeletedFolder folder: OrganizationalUnit, on db: any Database) async throws {
        let folderIDs = try await folder.selfAndDescendantIDs(on: db)
        guard !folderIDs.isEmpty else { return }
        let projectIDs = try await Project.query(on: db)
            .filter(\.$organizationalUnit.$id ~~ folderIDs)
            .all(\.$id)
        try await revokeBindings(forDeletedProjects: projectIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .organizationalUnit, nodeIDs: folderIDs, on: db)
    }

    /// Revoke every binding on an organization node and on everything that
    /// cascades away with it: its folders, the projects held directly by the
    /// organization or by any of those folders, and each project's own
    /// cascading children.
    ///
    /// Groups are swept as principals rather than nodes — a group is not a
    /// bindable node, but it cascades on `organization_id` and its grants
    /// elsewhere would outlive it, the cleanup its own delete endpoint does.
    static func revokeBindings(forDeletedOrganization organizationID: UUID, on db: any Database) async throws {
        let folderIDs = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all(\.$id)
        var projectIDs = try await Project.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all(\.$id)
        if !folderIDs.isEmpty {
            let folderProjectIDs = try await Project.query(on: db)
                .filter(\.$organizationalUnit.$id ~~ folderIDs)
                .all(\.$id)
            projectIDs = Array(Set(projectIDs).union(folderProjectIDs))
        }

        let groupIDs = try await Group.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all(\.$id)
        for groupID in groupIDs {
            try await RoleBindingService.revokeAll(principalType: .group, principalID: groupID, on: db)
        }

        try await revokeBindings(forDeletedProjects: projectIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .organizationalUnit, nodeIDs: folderIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .organization, nodeID: organizationID, on: db)
    }
}
