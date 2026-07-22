import Foundation
import Vapor

/// The action vocabulary, as the role editor needs to see it (issue #605).
///
/// Static: it is generated from `IAMRoleRegistry` and `CedarSchemaBuilder`,
/// the same two places the Cedar schema comes from, so the picker in the UI
/// can never offer an action the write path would reject — or omit one it
/// would accept.
enum IAMActionCatalog {

    /// One action, with everything the editor needs to place it.
    struct Entry: Content, Equatable, Sendable {
        let action: String
        let service: String
        /// The tree-node types this action can be requested against, in wire
        /// naming (`virtual_machine`, `organizational_unit`, …). Container
        /// types appear because `create`/`list` checks target the container.
        let resourceTypes: [String]
        /// The seeded roles whose action group carries this action. Empty for
        /// an action no default role grants — which is a fine thing for a
        /// custom role to grant, and worth showing as such.
        let roles: [String]
        /// Granted by bare organization membership, with no binding behind it
        /// (`IAMRoleRegistry.membershipDerivedActions`). Including such an
        /// action in a custom role is legal but buys nothing inside the org.
        let membershipDerived: Bool
    }

    /// The actions of one service, the grouping the editor renders.
    struct ServiceGroup: Content, Equatable, Sendable {
        let service: String
        let actions: [Entry]
    }

    struct Response: Content, Equatable, Sendable {
        let services: [ServiceGroup]
    }

    /// The whole catalog, sorted so two calls — and two deployments — agree.
    static func catalog() -> Response {
        let entries = IAMRoleRegistry.allActions.sorted().map(entry(for:))
        let grouped = Dictionary(grouping: entries, by: \.service)
        return Response(
            services: grouped.keys.sorted().map { service in
                ServiceGroup(service: service, actions: grouped[service] ?? [])
            })
    }

    static func entry(for action: String) -> Entry {
        let service = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        let cedarTypes = Set(CedarSchemaBuilder.resourceTypes(for: action).map(\.rawValue))
        return Entry(
            action: action,
            service: service,
            resourceTypes: IAMNodeType.allCases
                .filter { cedarTypes.contains($0.cedarEntityType.rawValue) }
                .map(\.rawValue)
                .sorted(),
            roles: IAMRoleRegistry.roles(granting: action).map(\.rawValue).sorted(),
            membershipDerived: IAMRoleRegistry.membershipDerivedActions.contains(action)
        )
    }
}
