import Foundation
import Testing

@testable import App

/// IAM phase 4 (issue #481): the legacy-permission → IAM-action translator.
/// The table below is the inventory of (permission, resource type) pairs the
/// middleware and handlers actually check — each must translate to a registry
/// action that is schema-applicable on the node, or decision recording logs
/// it as a coverage gap.
@Suite("IAM Shadow Translation Tests")
struct IAMShadowTranslationTests {

    private let id = UUID().uuidString

    private func action(
        _ permission: String, on resourceType: String, path: String = "/api/test"
    ) -> String? {
        IAMActionTranslator.translate(
            permission: permission, resourceType: resourceType, resourceID: id, path: path
        )?.action
    }

    @Test("Every check-site pair translates to its registry action")
    func checkSiteInventory() {
        // (permission, resourceType, expected action) — assembled from every
        // `checkPermission` call site plus the middleware's method mapping.
        let inventory: [(String, String, String)] = [
            // AuthorizationMiddleware method-derived verbs
            ("read", "virtual_machine", "vm:read"),
            ("create", "virtual_machine", "vm:create"),
            ("update", "virtual_machine", "vm:update"),
            ("delete", "virtual_machine", "vm:delete"),
            ("start", "virtual_machine", "vm:start"),
            ("stop", "virtual_machine", "vm:stop"),
            ("restart", "virtual_machine", "vm:restart"),
            ("pause", "virtual_machine", "vm:pause"),
            ("resume", "virtual_machine", "vm:resume"),
            ("read", "sandbox", "sandbox:read"),
            ("exec", "sandbox", "sandbox:exec"),
            // In-guest execution on a VM (issue #804). Two actions because
            // they differ in what the platform can attest to afterwards, not
            // in how much they can do — see `guestExecutionActions`.
            ("exec", "virtual_machine", "vm:exec"),
            ("run", "virtual_machine", "vm:runCommand"),
            ("snapshot", "sandbox", "sandbox:snapshot"),
            ("snapshot", "volume", "volume:snapshot"),
            // Full-VM checkpoints (issue #564) join the same shape.
            ("snapshot", "virtual_machine", "vm:snapshot"),
            ("restore", "virtual_machine", "vm:restore"),
            ("delete", "vm_snapshot", "vm:snapshot"),
            ("restore", "vm_snapshot", "vm:restore"),
            ("read", "vm_snapshot", "vm:read"),
            // Snapshot subresources: delete/restore are the parent's snapshot
            // vocabulary, not resource deletes.
            ("read", "sandbox_snapshot", "sandbox:read"),
            ("delete", "sandbox_snapshot", "sandbox:snapshot"),
            ("restore", "sandbox_snapshot", "sandbox:restore"),
            ("delete", "volume_snapshot", "volume:snapshot"),
            ("restore", "volume_snapshot", "volume:restore"),
            // Container view/manage pairs
            ("view_organization", "organization", "org:read"),
            ("manage_organization", "organization", "org:update"),
            ("manage_members", "organization", "org:update"),
            ("manage_ou", "organizational_unit", "folder:update"),
            ("view_project", "project", "project:read"),
            ("update_project", "project", "project:update"),
            ("manage_project", "project", "project:update"),
            // Infrastructure
            ("view", "site", "site:read"),
            ("manage", "site", "site:manage"),
            ("view", "agent", "agent:read"),
            ("manage", "agent", "agent:manage"),
            ("manage_agents", "organization", "agent:manage"),
            ("manage_agents", "organizational_unit", "agent:manage"),
            // Resource-specific verbs
            ("view_console", "virtual_machine", "vm:viewConsole"),
            ("download", "image", "image:download"),
            ("read", "image", "image:read"),
            ("update", "image", "image:update"),
            ("read", "network", "network:read"),
            ("read", "volume", "volume:read"),
            ("read", "floating_ip", "floatingip:read"),
            ("delete", "floating_ip", "floatingip:release"),
            // Project-scoped creation permissions
            ("create_volume", "project", "volume:create"),
            ("create_network", "project", "network:create"),
            ("create_floating_ip", "project", "floatingip:create"),
        ]

        for (permission, resourceType, expected) in inventory {
            let translated = action(permission, on: resourceType)
            #expect(translated == expected, "\(permission) on \(resourceType)")
        }
    }

    @Test("create_resources resolves through the route being created")
    func createResourcesPathHint() {
        #expect(action("create_resources", on: "project", path: "/api/vms") == "vm:create")
        #expect(action("create_resources", on: "project", path: "/api/sandboxes") == "sandbox:create")
        #expect(action("create_resources", on: "project", path: "/api/other") == nil)
    }

    @Test("Untranslatable checks return nil rather than guessing")
    func untranslatable() {
        // Unknown resource type (no IAM node type)
        #expect(action("read", on: "floating_ip_pool") == nil)
        // Unknown permission
        #expect(action("frobnicate", on: "virtual_machine") == nil)
        // Non-UUID resource id (collection wildcard)
        #expect(
            IAMActionTranslator.translate(
                permission: "read", resourceType: "virtual_machine", resourceID: "*",
                path: "/api/vms") == nil)
        // A verb that exists but not for this service
        #expect(action("run", on: "sandbox") == nil)
        // `export` is snapshot mobility, which only sandboxes have: a full-VM
        // checkpoint lives inside the VM's own disks and cannot leave its host.
        #expect(action("export", on: "virtual_machine") == nil)
        #expect(action("export", on: "volume") == nil)
    }

    /// The privilege tier a legacy gate's translated action is expected to sit
    /// at, expressed as the exact set of roles that must carry it. This is the
    /// executable form of the STR-116 audit's "gate → action → roles" table:
    /// the failure this guards is a legacy name silently resolving to an action
    /// at the wrong privilege level (the `manage_project → project:update`
    /// shape, STR-107), which no request-level test notices as long as the
    /// request still succeeds.
    private enum PrivilegeTier {
        /// Every role holds it (a read/list/download action a viewer has).
        case viewerOrAbove
        /// Operator and up — the lifecycle verbs, not the viewer's reads.
        case operatorOrAbove
        /// Editor and up — create/update/delete and the resource verbs.
        case editorOrAbove
        /// Admin only — IAM, quota, container administration, infrastructure.
        case adminOnly
        /// No seeded role carries it: membership-derived, or the guest-exec
        /// actions that live only in an authored custom role.
        case noSeededRole

        var expectedRoles: Set<IAMRole> {
            switch self {
            case .viewerOrAbove: return [.viewer, .operator, .editor, .admin]
            case .operatorOrAbove: return [.operator, .editor, .admin]
            case .editorOrAbove: return [.editor, .admin]
            case .adminOnly: return [.admin]
            case .noSeededRole: return []
            }
        }
    }

    @Test("Every legacy gate resolves to an action at its intended privilege tier")
    func translationPrivilegeTiers() {
        // (permission, resourceType, expected tier) — one row per legacy gate
        // in `IAMActionTranslation`, classified by the privilege its call sites
        // intend (see the STR-116 audit doc). A remap that moves an action
        // across tiers — the class of defect STR-107 was — fails here.
        let table: [(String, String, PrivilegeTier)] = [
            // Reads: viewer and up.
            ("read", "virtual_machine", .viewerOrAbove),
            ("view_project", "project", .viewerOrAbove),
            ("view_organization", "organization", .viewerOrAbove),
            ("view_ou", "organizational_unit", .viewerOrAbove),
            ("view", "site", .viewerOrAbove),
            ("view", "agent", .viewerOrAbove),
            ("download", "image", .viewerOrAbove),
            // Lifecycle verbs: operator and up.
            ("start", "virtual_machine", .operatorOrAbove),
            ("stop", "virtual_machine", .operatorOrAbove),
            ("restart", "virtual_machine", .operatorOrAbove),
            ("pause", "virtual_machine", .operatorOrAbove),
            ("resume", "virtual_machine", .operatorOrAbove),
            ("exec", "sandbox", .operatorOrAbove),
            // Resource mutation: editor and up. `manage_project` and
            // `update_project` are deliberately here — updating a project's
            // metadata is an editor act. The STR-107 defect was a *gate*
            // (`requireProjectAdmin`) treating this editor action as admin, not
            // the translation; the gate now asks `iam:setPolicy` directly.
            ("create", "virtual_machine", .editorOrAbove),
            ("update", "virtual_machine", .editorOrAbove),
            ("delete", "virtual_machine", .editorOrAbove),
            ("manage_project", "project", .editorOrAbove),
            ("update_project", "project", .editorOrAbove),
            ("create_volume", "project", .editorOrAbove),
            ("create_network", "project", .editorOrAbove),
            ("create_floating_ip", "project", .editorOrAbove),
            ("create_security_group", "project", .editorOrAbove),
            ("create_dns_zone", "project", .editorOrAbove),
            ("view_console", "virtual_machine", .editorOrAbove),
            ("snapshot", "virtual_machine", .editorOrAbove),
            ("restore", "virtual_machine", .editorOrAbove),
            ("delete", "floating_ip", .editorOrAbove),
            ("delete", "vm_snapshot", .editorOrAbove),
            // Container and infrastructure administration: admin only.
            ("manage_members", "organization", .adminOnly),
            ("manage_organization", "organization", .adminOnly),
            ("manage_ou", "organizational_unit", .adminOnly),
            ("manage", "site", .adminOnly),
            ("manage", "agent", .adminOnly),
            ("manage_agents", "organization", .adminOnly),
            // Guest execution: no seeded role, by design (issue #804).
            ("exec", "virtual_machine", .noSeededRole),
            ("run", "virtual_machine", .noSeededRole),
        ]

        for (permission, resourceType, tier) in table {
            guard let translated = action(permission, on: resourceType) else {
                Issue.record("\(permission) on \(resourceType) did not translate")
                continue
            }
            let granting = IAMRoleRegistry.roles(granting: translated)
            #expect(
                granting == tier.expectedRoles,
                "\(permission) on \(resourceType) → \(translated): roles \(granting) != \(tier.expectedRoles)")
        }
    }

    @Test("Every translation is a registry action applicable to its node type")
    func translationsAreSchemaValid() throws {
        // The translator's own guard enforces this; the test pins it against
        // the vocabulary evolving out from under the mapping table.
        let samples: [(String, String)] = [
            ("read", "virtual_machine"), ("view_project", "project"),
            ("manage_members", "organization"), ("delete", "sandbox_snapshot"),
            ("create_volume", "project"), ("manage_agents", "organizational_unit"),
            ("delete", "floating_ip"),
        ]
        for (permission, resourceType) in samples {
            let translation = IAMActionTranslator.translate(
                permission: permission, resourceType: resourceType, resourceID: id, path: "/")
            let translated = try #require(translation)
            let isRegistryAction = IAMRoleRegistry.allActions.contains(translated.action)
            #expect(isRegistryAction, "\(translated.action)")
            let applies = CedarSchemaBuilder.resourceTypes(for: translated.action)
                .contains(translated.node.type.cedarEntityType)
            #expect(applies, "\(translated.action)")
        }
    }
}
