import Foundation
import Vapor
import Fluent

/// Resolves the breadcrumb path (organization → OU chain → project → VM) for an
/// entity in the hierarchy. Extracted from `HierarchyController` so the recursive
/// path assembly can be tested on its own.
///
/// Assembly stays a pure function of the rows; ``visibleComponents(_:on:)`` is
/// the separate step that reduces a path to the components one caller may read.
/// Keeping them apart is what lets the assembly be tested without a request, and
/// makes the filtering a single reviewable rule rather than a condition threaded
/// through the recursion.
struct HierarchyPathResolver {
    /// Builds the ordered path components from the organization root down to the
    /// given entity. Unknown entity types yield just the organization root.
    static func buildEntityPath(entityType: String, entityID: UUID, organizationID: UUID, on db: Database) async throws
        -> [PathComponent]
    {
        var components: [PathComponent] = []

        // Add organization as root
        if let org = try await Organization.find(organizationID, on: db) {
            components.append(PathComponent(id: organizationID, name: org.name, type: "organization"))
        }

        switch entityType {
        // Accept both the resolver's canonical token and the "ou" filter token that
        // HierarchySearchService emits/accepts, so a caller using either vocabulary
        // gets a real path instead of silently falling through to org-root-only.
        case "organizational_unit", "ou":
            // Scope to the requested org: resolving an OU from another org would
            // leak its name (and ancestor names) to a member of this org.
            if let ou = try await OrganizationalUnit.find(entityID, on: db), ou.$organization.id == organizationID {
                // Walk from the target OU up to the root, collecting each ancestor
                // (including the target) so the chain reads root-first.
                var ouChain: [OrganizationalUnit] = []
                var currentOU: OrganizationalUnit? = ou

                while let node = currentOU {
                    ouChain.insert(node, at: 0)
                    if let parentID = node.$parentOU.id {
                        currentOU = try await OrganizationalUnit.find(parentID, on: db)
                    } else {
                        currentOU = nil
                    }
                }

                for ou in ouChain {
                    components.append(PathComponent(id: ou.id!, name: ou.name, type: "organizational_unit"))
                }
            }

        case "project":
            if let project = try await Project.find(entityID, on: db),
                try await project.getRootOrganizationId(on: db) == organizationID
            {
                // Add OU path if project belongs to OU
                if let ouID = project.$organizationalUnit.id {
                    let ouComponents = try await buildEntityPath(
                        entityType: "organizational_unit", entityID: ouID, organizationID: organizationID, on: db)
                    components.append(contentsOf: ouComponents.dropFirst())  // Remove duplicate org
                }
                components.append(PathComponent(id: entityID, name: project.name, type: "project"))
            }

        case "vm":
            // Scope to the requested org via the VM's project, so a VM in another
            // org isn't resolvable by name here.
            if let vm = try await VM.find(entityID, on: db),
                let project = try await Project.find(vm.$project.id, on: db),
                try await project.getRootOrganizationId(on: db) == organizationID
            {
                // Add project path
                let projectComponents = try await buildEntityPath(
                    entityType: "project", entityID: vm.$project.id, organizationID: organizationID, on: db)
                components.append(contentsOf: projectComponents.dropFirst())  // Remove duplicate org
                components.append(PathComponent(id: entityID, name: vm.name, type: "vm"))
            }

        default:
            break
        }

        return components
    }

    /// The components of an assembled path whose entity the caller may read.
    ///
    /// A breadcrumb names things, and a name is the disclosure `folder:read` /
    /// `project:read` / `vm:read` gate. Without this the route is the one door
    /// onto the hierarchy that issue #870 left open: `view_organization` — which
    /// bare org membership grants — was the whole check, so any member could
    /// resolve an arbitrary id into the names of the folders, project and VM
    /// above it, the same inventory the tree and the search results next door
    /// filter per row.
    ///
    /// Elides rather than refuses, matching the tree: a caller who may read a
    /// project but not its folder gets the project directly under the
    /// organization. Naming the folder is the part that is gated; that the
    /// project sits somewhere beneath the org is already in its own materialized
    /// `path`. The organization root is kept unconditionally — reaching this
    /// route at all is `view_organization` on it.
    static func visibleComponents(_ components: [PathComponent], on req: Request) async throws -> [PathComponent] {
        // One batch per node type (#687), in a fixed order so the decision log
        // records a stable sequence.
        let readChecks: [(type: String, nodeType: IAMNodeType, action: String)] = [
            ("organizational_unit", .organizationalUnit, "folder:read"),
            ("project", .project, "project:read"),
            ("vm", .virtualMachine, "vm:read"),
        ]

        var readable: Set<IAMNode> = []
        for check in readChecks {
            let nodes = components.filter { $0.type == check.type }.map { IAMNode(type: check.nodeType, id: $0.id) }
            readable.formUnion(try await req.canFilter(check.action, on: nodes))
        }

        return components.filter { component in
            guard let check = readChecks.first(where: { $0.type == component.type }) else {
                // The organization root, and any component type with no read
                // action of its own.
                return true
            }
            return readable.contains(IAMNode(type: check.nodeType, id: component.id))
        }
    }
}
