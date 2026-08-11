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
            .image, .network, .securityGroup, .floatingIP, .loadBalancer, .dnsZone, .volume, .volumeSnapshot,
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

    /// The *principal* types whose rows cascade away with a parent's, keyed the
    /// same way and inherited the same way.
    ///
    /// A principal is not a node — nothing binds *to* a group or a workload
    /// registration — so `cascadingChildren` cannot describe them and the
    /// node-keyed half of the guard is blind to them. They strand rows by the
    /// mirror-image mechanism: the bindings a vanished principal *holds* have
    /// no more owner than the bindings on a vanished node, and each one's own
    /// delete endpoint sweeps them for exactly that reason.
    static let cascadingPrincipals: [IAMNodeType: [IAMPrincipalType]] = [
        // A VM's instance-identity registration (STR-55) cascades on
        // `workload_registrations.vm_id`, and that row *is* a principal — so
        // deleting a VM strands every grant its identity holds unless the sweep
        // below runs first.
        .virtualMachine: [.workload],
        .project: [.serviceAccount],
        // `workload_registrations` cascades on `service_account_id` and
        // `vm_id` as well as on `organization_id`, so a project reaches the
        // table through its accounts. Only `kind == .workload` rows are
        // principals in their own right, and those never carry a service
        // account — but the sweep is written to the foreign key rather than to
        // that invariant.
        .serviceAccount: [.workload],
        .organization: [.group, .workload],
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

        // The VM's instance-identity registration (STR-55) cascades away with
        // the VM row, and the grants that principal *holds* are orphaned by the
        // cascade exactly as a service account's are by a project delete. Read
        // before the delete, for the same reason the checkpoints above are.
        let registrationIDs = try await WorkloadRegistration.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(
            principalType: .workload, principalIDs: registrationIDs, on: db)

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

    /// Volume counterpart: the volume node plus the snapshots that cascade away
    /// with it (STR-148). Same read-before-delete ordering requirement.
    static func revokeBindings(forDeletedVolume volumeID: UUID, on db: any Database) async throws {
        let snapshotIDs = try await VolumeSnapshot.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .volumeSnapshot, nodeIDs: snapshotIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .volume, nodeID: volumeID, on: db)
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
        try await RoleBindingService.revokeAll(
            principalType: .serviceAccount, principalIDs: serviceAccountIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .serviceAccount, nodeIDs: serviceAccountIDs, on: db)

        // Registry rows cascade with the account they name. Only a
        // `kind == .workload` row is a principal in its own right, and those
        // carry no service account — so this finds nothing today. It is
        // written to the foreign key rather than to that invariant, because
        // the foreign key is what the database will actually act on.
        if !serviceAccountIDs.isEmpty {
            let workloadIDs = try await WorkloadRegistration.query(on: db)
                .filter(\.$serviceAccount.$id ~~ serviceAccountIDs)
                .filter(\.$kind == .workload)
                .all(\.$id)
            try await RoleBindingService.revokeAll(
                principalType: .workload, principalIDs: workloadIDs, on: db)
        }

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

        let loadBalancerIDs = try await LoadBalancer.query(on: db)
            .filter(\.$project.$id ~~ projectIDs).all(\.$id)
        try await RoleBindingService.revokeAll(
            nodeType: .loadBalancer, nodeIDs: loadBalancerIDs, on: db)

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
    /// projects, so in practice there is nothing below the folder to sweep. The
    /// subtree walk narrows the window rather than closing it: it covers a row
    /// committed between the endpoint's check and this sweep, but under READ
    /// COMMITTED the sweep's reads and the subsequent `DELETE` take different
    /// snapshots, so a row committed *after* the sweep is still invisible here
    /// and still cascades away. Closing that last gap needs the folder row
    /// locked `FOR UPDATE` (an FK child insert takes `FOR KEY SHARE` on it),
    /// which is a concurrency change worth making deliberately rather than as
    /// a side effect of this one.
    static func revokeBindings(forDeletedFolder folder: OrganizationalUnit, on db: any Database) async throws {
        let folderID = try folder.requireID()
        let descendantIDs = try await folder.descendants(on: db).compactMap(\.id)
        let folderIDs = [folderID] + descendantIDs
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
    /// Groups and directly registered workloads are swept as principals rather
    /// than nodes — neither is a bindable node, but both cascade on
    /// `organization_id` and their grants elsewhere would outlive them, the
    /// cleanup each one's own delete endpoint does.
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
        try await RoleBindingService.revokeAll(principalType: .group, principalIDs: groupIDs, on: db)

        // A `kind == .workload` registration *is* the principal (principal id
        // = row id), and the row is org-scoped. The `kind` filter is documentation
        // rather than necessity: agent and service-account rows hold nothing
        // under `.workload`.
        let workloadIDs = try await WorkloadRegistration.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$kind == .workload)
            .all(\.$id)
        try await RoleBindingService.revokeAll(principalType: .workload, principalIDs: workloadIDs, on: db)

        try await revokeBindings(forDeletedProjects: projectIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .organizationalUnit, nodeIDs: folderIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .organization, nodeID: organizationID, on: db)
    }
}
