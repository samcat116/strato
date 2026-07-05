import Foundation
import Vapor
import Fluent

/// Resolves the breadcrumb path (organization → OU chain → project → VM) for an
/// entity in the hierarchy. Extracted from `HierarchyController` so the recursive
/// path assembly can be tested on its own.
struct HierarchyPathResolver {
    /// Builds the ordered path components from the organization root down to the
    /// given entity. Unknown entity types yield just the organization root.
    static func buildEntityPath(entityType: String, entityID: UUID, organizationID: UUID, on db: Database) async throws -> [PathComponent] {
        var components: [PathComponent] = []

        // Add organization as root
        if let org = try await Organization.find(organizationID, on: db) {
            components.append(PathComponent(id: organizationID, name: org.name, type: "organization"))
        }

        switch entityType {
        case "organizational_unit":
            if let ou = try await OrganizationalUnit.find(entityID, on: db) {
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
            if let project = try await Project.find(entityID, on: db) {
                // Add OU path if project belongs to OU
                if let ouID = project.$organizationalUnit.id {
                    let ouComponents = try await buildEntityPath(entityType: "organizational_unit", entityID: ouID, organizationID: organizationID, on: db)
                    components.append(contentsOf: ouComponents.dropFirst()) // Remove duplicate org
                }
                components.append(PathComponent(id: entityID, name: project.name, type: "project"))
            }

        case "vm":
            if let vm = try await VM.find(entityID, on: db) {
                // Add project path
                let projectComponents = try await buildEntityPath(entityType: "project", entityID: vm.$project.id, organizationID: organizationID, on: db)
                components.append(contentsOf: projectComponents.dropFirst()) // Remove duplicate org
                components.append(PathComponent(id: entityID, name: vm.name, type: "vm"))
            }

        default:
            break
        }

        return components
    }
}
