import Foundation
import Testing

@testable import App

/// IAM phase 4 (issue #481): the SpiceDB-permission → IAM-action translator.
/// The table below is the inventory of (permission, resource type) pairs the
/// middleware and handlers actually check — each must translate to a registry
/// action that is schema-applicable on the node, or shadow evaluation records
/// it as a coverage gap.
@Suite("IAM Shadow Translation Tests")
struct IAMShadowTranslationTests {

    private let id = UUID().uuidString

    private func action(
        _ permission: String, on resourceType: String, path: String = "/api/test"
    ) -> String? {
        IAMShadowTranslator.translate(
            permission: permission, resourceType: resourceType, resourceID: id, path: path
        )?.action
    }

    @Test("Every check-site pair translates to its registry action")
    func checkSiteInventory() {
        // (permission, resourceType, expected action) — assembled from every
        // `checkPermission` call site plus the middleware's method mapping.
        let inventory: [(String, String, String)] = [
            // SpiceDBAuthMiddleware method-derived verbs
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
            ("snapshot", "sandbox", "sandbox:snapshot"),
            ("snapshot", "volume", "volume:snapshot"),
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
            IAMShadowTranslator.translate(
                permission: "read", resourceType: "virtual_machine", resourceID: "*",
                path: "/api/vms") == nil)
        // A verb that exists but not for this service
        #expect(action("exec", on: "virtual_machine") == nil)
        #expect(action("snapshot", on: "virtual_machine") == nil)
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
            let translation = IAMShadowTranslator.translate(
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
