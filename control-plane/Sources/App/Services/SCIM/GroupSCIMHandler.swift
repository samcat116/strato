import ControlPlanePostgres
import Foundation
import Logging
import SwiftSCIM

struct GroupSCIMHandler: SCIMResourceHandler, Sendable {
    typealias Resource = SCIMGroup

    static let endpoint = "Groups"
    static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:Group"

    let groups: GroupsPersistence
    let externalIDs: SCIMExternalIDsPersistence
    let organizationID: UUID
    let logger: Logger

    func create(_ resource: SCIMGroup, context: SCIMRequestContext) async throws -> SCIMGroup {
        let group: GroupSnapshot
        do {
            group = try await groups.create(
                GroupWrite(
                    organizationID: organizationID,
                    name: resource.displayName,
                    description: "",
                    scimProvisioned: true
                )
            )
        } catch GroupPersistenceError.duplicateName {
            throw SCIMServerError.conflict(
                detail: "Group with name '\(resource.displayName)' already exists in this organization"
            )
        }

        if let externalID = resource.externalId {
            try await externalIDs.assign(
                externalID: externalID,
                to: group.id,
                resourceType: .group,
                organizationID: organizationID
            )
        }
        if let members = resource.members {
            try await addMembers(
                members.compactMap(\.value).compactMap(UUID.init(uuidString:)),
                to: group.id
            )
        }
        return try await groupToSCIMGroup(group, context: context)
    }

    func get(id: String, context: SCIMRequestContext) async throws -> SCIMGroup {
        let group = try await requireGroup(id: id)
        return try await groupToSCIMGroup(group, context: context)
    }

    func replace(id: String, with resource: SCIMGroup, context: SCIMRequestContext) async throws -> SCIMGroup {
        let current = try await requireGroup(id: id)
        let group: GroupSnapshot
        do {
            guard
                let replaced = try await groups.replace(
                    GroupWrite(
                        id: current.id,
                        organizationID: current.organizationID,
                        name: resource.displayName,
                        description: current.description,
                        scimProvisioned: current.scimProvisioned
                    )
                )
            else { throw SCIMServerError.notFound(resourceType: "Group", id: id) }
            group = replaced
        } catch GroupPersistenceError.duplicateName {
            throw SCIMServerError.conflict(
                detail: "Group with name '\(resource.displayName)' already exists in this organization"
            )
        }

        if let externalID = resource.externalId {
            try await externalIDs.assign(
                externalID: externalID,
                to: group.id,
                resourceType: .group,
                organizationID: organizationID
            )
        }
        try await replaceMembers(
            resource.members?.compactMap(\.value).compactMap(UUID.init(uuidString:)) ?? [],
            in: group.id
        )
        return try await groupToSCIMGroup(group, context: context)
    }

    func delete(id: String, context: SCIMRequestContext) async throws {
        let group = try await requireGroup(id: id)
        guard try await groups.delete(id: group.id, organizationID: organizationID) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }
        _ = try await externalIDs.remove(
            internalID: group.id,
            resourceType: .group,
            organizationID: organizationID
        )
    }

    func search(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMListResponse<SCIMGroup> {
        let page = try await groups.search(
            organizationID: organizationID,
            filters: try filters(query.filter),
            offset: query.offset,
            limit: query.count
        )
        var resources: [SCIMGroup] = []
        resources.reserveCapacity(page.items.count)
        for group in page.items {
            resources.append(try await groupToSCIMGroup(group, context: context))
        }
        return SCIMListResponse(
            totalResults: page.total,
            resources: resources,
            startIndex: query.startIndex,
            itemsPerPage: query.count
        )
    }

    func patch(id: String, operations: [SCIMPatchOperation], context: SCIMRequestContext) async throws -> SCIMGroup {
        let current = try await requireGroup(id: id)
        var name = current.name
        for operation in operations {
            name = try await applyPatchOperation(operation, currentName: name, groupID: current.id)
        }

        let group: GroupSnapshot
        do {
            guard
                let replaced = try await groups.replace(
                    GroupWrite(
                        id: current.id,
                        organizationID: current.organizationID,
                        name: name,
                        description: current.description,
                        scimProvisioned: current.scimProvisioned
                    )
                )
            else { throw SCIMServerError.notFound(resourceType: "Group", id: id) }
            group = replaced
        } catch GroupPersistenceError.duplicateName {
            throw SCIMServerError.conflict(
                detail: "Group with name '\(name)' already exists in this organization"
            )
        }
        return try await groupToSCIMGroup(group, context: context)
    }

    private func requireGroup(id: String) async throws -> GroupSnapshot {
        guard let groupID = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }
        guard let group = try await groups.ownedGroup(id: groupID, organizationID: organizationID) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }
        return group
    }

    private func groupToSCIMGroup(
        _ group: GroupSnapshot,
        context: SCIMRequestContext
    ) async throws -> SCIMGroup {
        let externalID = try await externalIDs.externalID(
            internalID: group.id,
            resourceType: .group,
            organizationID: organizationID
        )
        let members = try await groups.members(groupID: group.id)
        let scimMembers: [GroupMember]? = members.isEmpty ? nil : members.map { member in
            GroupMember(
                value: member.userID.uuidString,
                ref: context.resourceLocation(endpoint: "Users", id: member.userID.uuidString),
                display: member.displayName,
                type: "User"
            )
        }
        return SCIMGroup(
            id: group.id.uuidString,
            externalId: externalID,
            meta: SCIMResourceMeta(
                resourceType: "Group",
                created: group.createdAt,
                lastModified: group.updatedAt,
                location: context.resourceLocation(endpoint: Self.endpoint, id: group.id.uuidString),
                version: group.updatedAt.map { "W/\"\($0.timeIntervalSince1970)\"" }
            ),
            displayName: group.name,
            members: scimMembers
        )
    }

    private func addMembers(_ userIDs: [UUID], to groupID: UUID) async throws {
        let result = try await groups.addMembers(
            userIDs,
            to: groupID,
            organizationID: organizationID
        )
        try recordMutationResult(result, groupID: groupID)
    }

    private func replaceMembers(_ userIDs: [UUID], in groupID: UUID) async throws {
        let result = try await groups.replaceMembers(
            userIDs,
            in: groupID,
            organizationID: organizationID
        )
        try recordMutationResult(result, groupID: groupID)
    }

    private func removeMembers(_ userIDs: [UUID], from groupID: UUID) async throws {
        let result = try await groups.removeMembers(
            userIDs,
            from: groupID,
            organizationID: organizationID
        )
        try recordMutationResult(result, groupID: groupID)
    }

    private func recordMutationResult(_ result: GroupMemberMutationResult, groupID: UUID) throws {
        guard result.groupFound else {
            throw SCIMServerError.notFound(resourceType: "Group", id: groupID.uuidString)
        }
        for userID in result.ineligibleUserIDs {
            logger.warning(
                "SCIM group membership add skipped because user is outside the organization",
                metadata: [
                    "user_id": .string(userID.uuidString),
                    "organization_id": .string(organizationID.uuidString),
                    "group_id": .string(groupID.uuidString),
                ]
            )
        }
    }

    private func applyPatchOperation(
        _ operation: SCIMPatchOperation,
        currentName: String,
        groupID: UUID
    ) async throws -> String {
        guard let path = operation.path else {
            guard
                operation.op != .remove,
                let value = operation.value,
                case .object(let fields) = value,
                let displayName = fields["displayName"],
                case .string(let name) = displayName
            else { return currentName }
            return name
        }

        let lowercasePath = path.lowercased()
        switch lowercasePath {
        case "displayname":
            guard
                operation.op != .remove,
                let value = operation.value,
                case .string(let name) = value
            else { return currentName }
            return name

        case "members":
            switch operation.op {
            case .add:
                if let value = operation.value {
                    try await addMembers(extractMemberIDs(from: value), to: groupID)
                }
            case .remove:
                if let value = operation.value {
                    try await removeMembers(extractMemberIDs(from: value), from: groupID)
                } else {
                    try await replaceMembers([], in: groupID)
                }
            case .replace:
                try await replaceMembers(
                    operation.value.map(extractMemberIDs(from:)) ?? [],
                    in: groupID
                )
            }
            return currentName

        default:
            if lowercasePath.hasPrefix("members["), operation.op == .remove,
                let match = lowercasePath.range(of: "value eq \"", options: .caseInsensitive),
                let endQuote = lowercasePath.range(
                    of: "\"",
                    range: match.upperBound..<lowercasePath.endIndex
                ),
                let memberID = UUID(uuidString: String(lowercasePath[match.upperBound..<endQuote.lowerBound]))
            {
                try await removeMembers([memberID], from: groupID)
            }
            return currentName
        }
    }

    private func extractMemberIDs(from value: SCIMPatchValue) -> [UUID] {
        switch value {
        case .array(let items):
            return items.compactMap { item in
                guard case .object(let fields) = item,
                    let value = fields["value"], case .string(let id) = value
                else { return nil }
                return UUID(uuidString: id)
            }
        case .object(let fields):
            guard let value = fields["value"], case .string(let id) = value else { return [] }
            return UUID(uuidString: id).map { [$0] } ?? []
        default:
            return []
        }
    }

    private func filters(_ expression: SCIMFilterExpression?) throws -> [GroupNameFilter] {
        guard let expression else { return [] }
        switch expression {
        case .attribute(let path, let op, let value):
            guard path.lowercased() == "displayname" else { return [] }
            let text = try value.requireText(path: path)
            switch op {
            case .equal: return [.equal(text)]
            case .notEqual: return [.notEqual(text)]
            case .contains: return [.contains(text)]
            case .startsWith: return [.startsWith(text)]
            case .endsWith: return [.endsWith(text)]
            case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .present:
                return []
            }
        case .logical(let operation, let left, let right):
            guard operation == .and else {
                throw SCIMServerError.invalidFilter(
                    detail: "SCIM logical filter operator '\(operation)' is not supported"
                )
            }
            return try filters(left) + filters(right)
        case .not:
            throw SCIMServerError.invalidFilter(detail: "SCIM NOT filter is not supported")
        case .present(let path):
            return path.lowercased() == "displayname" ? [.present] : []
        case .group(let inner):
            return try filters(inner)
        case .empty:
            return []
        }
    }
}
