import Foundation

// IAM phase 4 (issue #481): the SpiceDB-permission → IAM-action translator.
//
// Until cutover the two authorization vocabularies deliberately coexist:
// SpiceDB permissions (`read`, `manage_project`, `view_organization`) gate
// requests, and IAM actions (`vm:read`, `project:update`, `org:read`) are what
// the Cedar policy set evaluates. Shadow evaluation has to bridge them: each
// SpiceDB check is translated to the IAM action naming the *act being gated*,
// so a verdict mismatch reflects a real semantic difference between the two
// models — not a translation artifact. Untranslatable checks are recorded as
// such in the decision log rather than silently skipped, so coverage gaps are
// visible and countable.

/// One translated check: the IAM action and the tree node to evaluate it on.
struct IAMShadowTranslation: Equatable, Sendable {
    let action: String
    let node: IAMNode
}

enum IAMShadowTranslator {

    /// Translate a SpiceDB check into the Cedar vocabulary, or nil when the
    /// pair has no faithful IAM-action equivalent (unknown resource type,
    /// non-UUID resource id, or a permission nobody mapped).
    ///
    /// `path` disambiguates the one genuinely ambiguous permission:
    /// `create_resources` on a project gates whichever resource kind the
    /// route is creating.
    static func translate(
        permission: String, resourceType: String, resourceID: String, path: String
    ) -> IAMShadowTranslation? {
        guard let nodeType = IAMNodeType(rawValue: resourceType),
            let nodeID = UUID(uuidString: resourceID)
        else { return nil }
        guard let action = action(permission: permission, nodeType: nodeType, path: path) else { return nil }

        // Belt and braces: only emit actions the registry knows, applicable to
        // this node type per the generated schema. A bad mapping here would
        // surface as request-validation errors on every check, not as verdicts.
        guard IAMRoleRegistry.allActions.contains(action),
            CedarSchemaBuilder.resourceTypes(for: action).contains(nodeType.cedarEntityType)
        else { return nil }

        return IAMShadowTranslation(action: action, node: IAMNode(type: nodeType, id: nodeID))
    }

    /// The service prefix owning a node type's actions. Snapshots fold into
    /// their parent service — the registry models snapshot operations as
    /// `volume:*` / `sandbox:*` actions, not services of their own.
    private static func service(for nodeType: IAMNodeType) -> String {
        switch nodeType {
        case .organization: return "org"
        case .organizationalUnit: return "folder"
        case .project: return "project"
        case .virtualMachine: return "vm"
        case .sandbox, .sandboxSnapshot: return "sandbox"
        case .image: return "image"
        case .network: return "network"
        case .floatingIP: return "floatingip"
        case .volume, .volumeSnapshot: return "volume"
        case .site: return "site"
        case .agent: return "agent"
        }
    }

    private static func action(permission: String, nodeType: IAMNodeType, path: String) -> String? {
        let service = service(for: nodeType)
        switch permission {
        // The generic method-derived verbs (SpiceDBAuthMiddleware) and the
        // view/manage pairs the containers use.
        case "read", "view", "view_project", "view_organization":
            return "\(service):read"
        case "list":
            return "\(service):list"
        case "create":
            return "\(service):create"
        case "update", "update_project":
            return "\(service):update"
        case "delete":
            // Deleting a snapshot is the parent's snapshot permission, not a
            // resource delete (mirrors the middleware's subresource carve-out),
            // and a floating IP is released, not deleted.
            switch nodeType {
            case .sandboxSnapshot: return "sandbox:snapshot"
            case .volumeSnapshot: return "volume:snapshot"
            case .floatingIP: return "floatingip:release"
            default: return "\(service):delete"
            }

        // Lifecycle verbs are permissions of their own on VMs and sandboxes.
        case "start", "stop", "restart", "pause", "resume", "exec":
            return "\(service):\(permission)"
        case "snapshot":
            switch service {
            case "sandbox": return "sandbox:snapshot"
            case "volume": return "volume:snapshot"
            default: return nil
            }
        case "restore":
            switch service {
            case "sandbox": return "sandbox:restore"
            case "volume": return "volume:restore"
            default: return nil
            }
        case "view_console":
            return "vm:viewConsole"
        case "download":
            return "image:download"

        // Administrative control of containers and infrastructure. Managing an
        // org's members is an org-admin act; the registry has no finer action.
        case "manage_organization", "manage_members":
            return "org:update"
        case "manage_ou":
            return "folder:update"
        case "manage_project":
            return "project:update"
        case "manage":
            switch nodeType {
            case .site: return "site:manage"
            case .agent: return "agent:manage"
            default: return nil
            }
        case "manage_agents":
            return "agent:manage"

        // Project-scoped creation permissions. `create_resources` gates
        // whichever kind the route creates; the service-specific ones name it.
        case "create_resources":
            if path.hasPrefix("/api/vms") { return "vm:create" }
            if path.hasPrefix("/api/sandboxes") { return "sandbox:create" }
            return nil
        case "create_volume":
            return "volume:create"
        case "create_network":
            return "network:create"
        case "create_floating_ip":
            return "floatingip:create"

        default:
            return nil
        }
    }
}
