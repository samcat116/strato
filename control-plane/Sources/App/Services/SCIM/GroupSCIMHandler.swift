import Fluent
import Vapor
import SwiftSCIM

struct GroupSCIMHandler: SCIMResourceHandler, @unchecked Sendable {
    typealias Resource = SCIMGroup

    static let endpoint = "Groups"
    static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:Group"

    let db: Database
    let organizationID: UUID
    let spicedb: SpiceDBServiceProtocol

    // MARK: - Create

    func create(_ resource: SCIMGroup, context: SCIMRequestContext) async throws -> SCIMGroup {
        // Check for existing group with same name in this organization
        if let _ = try await App.Group.query(on: db)
            .filter(\.$name == resource.displayName)
            .filter(\.$organization.$id == organizationID)
            .first()
        {
            throw SCIMServerError.conflict(detail: "Group with name '\(resource.displayName)' already exists in this organization")
        }

        // Create group
        let group = App.Group(
            name: resource.displayName,
            description: "", // SCIM Groups don't have a description field
            organizationID: organizationID,
            scimProvisioned: true
        )
        try await group.save(on: db)

        guard let groupID = group.id else {
            throw SCIMServerError.internalError(detail: "Failed to create group")
        }

        // Store external ID mapping if provided
        if let externalId = resource.externalId {
            try await SCIMExternalID.upsert(
                organizationID: organizationID,
                resourceType: .group,
                externalId: externalId,
                internalId: groupID,
                on: db
            )
        }

        // Add members if provided
        if let members = resource.members {
            for member in members {
                if let memberID = member.value, let uuid = UUID(uuidString: memberID) {
                    try await addMemberToGroup(userID: uuid, groupID: groupID)
                }
            }
        }

        return try await groupToSCIMGroup(group, context: context)
    }

    // MARK: - Get

    func get(id: String, context: SCIMRequestContext) async throws -> SCIMGroup {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        guard let group = try await App.Group.query(on: db)
            .filter(\.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first()
        else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        return try await groupToSCIMGroup(group, context: context)
    }

    // MARK: - Replace

    func replace(id: String, with resource: SCIMGroup, context: SCIMRequestContext) async throws -> SCIMGroup {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        guard let group = try await App.Group.query(on: db)
            .filter(\.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first()
        else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        // Update group fields
        group.name = resource.displayName
        try await group.save(on: db)

        // Update external ID mapping if provided
        if let externalId = resource.externalId {
            try await SCIMExternalID.upsert(
                organizationID: organizationID,
                resourceType: .group,
                externalId: externalId,
                internalId: uuid,
                on: db
            )
        }

        // Replace members - remove all existing and add new ones
        try await removeAllMembersFromGroup(groupID: uuid)

        if let members = resource.members {
            for member in members {
                if let memberID = member.value, let memberUUID = UUID(uuidString: memberID) {
                    try await addMemberToGroup(userID: memberUUID, groupID: uuid)
                }
            }
        }

        return try await groupToSCIMGroup(group, context: context)
    }

    // MARK: - Delete

    func delete(id: String, context: SCIMRequestContext) async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        guard let group = try await App.Group.query(on: db)
            .filter(\.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first()
        else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        // Remove all members from SpiceDB
        let members = try await App.UserGroup.query(on: db)
            .filter(\.$group.$id == uuid)
            .all()

        for member in members {
            try await spicedb.removeUserFromGroup(
                userID: member.$user.id.uuidString,
                groupID: uuid.uuidString
            )
        }

        // Delete the group (cascade will remove UserGroup entries)
        try await group.delete(on: db)

        // Delete external ID mapping
        try await SCIMExternalID.deleteMapping(
            internalId: uuid,
            resourceType: .group,
            organizationID: organizationID,
            on: db
        )
    }

    // MARK: - Search

    func search(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMListResponse<SCIMGroup> {
        var groupQuery = App.Group.query(on: db)
            .filter(\.$organization.$id == organizationID)

        // Apply filter if present
        if let filter = query.filter {
            groupQuery = try applyFilter(filter, to: groupQuery)
        }

        // Get total count before pagination
        let totalCount = try await groupQuery.count()

        // Apply pagination
        let groups = try await groupQuery
            .offset(query.offset)
            .limit(query.count)
            .all()

        // Convert to SCIM resources
        var scimGroups: [SCIMGroup] = []
        for group in groups {
            let scimGroup = try await groupToSCIMGroup(group, context: context)
            scimGroups.append(scimGroup)
        }

        return SCIMListResponse(
            totalResults: totalCount,
            resources: scimGroups,
            startIndex: query.startIndex,
            itemsPerPage: query.count
        )
    }

    // MARK: - Patch (override default implementation for member updates)

    func patch(id: String, operations: [SCIMPatchOperation], context: SCIMRequestContext) async throws -> SCIMGroup {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        guard let group = try await App.Group.query(on: db)
            .filter(\.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first()
        else {
            throw SCIMServerError.notFound(resourceType: "Group", id: id)
        }

        for operation in operations {
            try await applyPatchOperation(operation, to: group, groupID: uuid)
        }

        try await group.save(on: db)

        return try await groupToSCIMGroup(group, context: context)
    }

    // MARK: - Helpers

    private func groupToSCIMGroup(_ group: App.Group, context: SCIMRequestContext) async throws -> SCIMGroup {
        guard let groupID = group.id else {
            throw SCIMServerError.internalError(detail: "Group has no ID")
        }

        let location = context.resourceLocation(endpoint: Self.endpoint, id: groupID.uuidString)

        // Get external ID if exists
        let externalId = try await SCIMExternalID.findExternalID(
            internalId: groupID,
            resourceType: .group,
            organizationID: organizationID,
            on: db
        )

        // Get group members
        let memberships = try await App.UserGroup.query(on: db)
            .filter(\.$group.$id == groupID)
            .with(\.$user)
            .all()

        let members: [GroupMember]? = memberships.isEmpty ? nil : memberships.map { membership in
            GroupMember(
                value: membership.$user.id.uuidString,
                ref: context.resourceLocation(endpoint: "Users", id: membership.$user.id.uuidString),
                display: membership.user.displayName,
                type: "User"
            )
        }

        let meta = SCIMResourceMeta(
            resourceType: "Group",
            created: group.createdAt,
            lastModified: group.updatedAt,
            location: location,
            version: group.updatedAt.map { "W/\"\($0.timeIntervalSince1970)\"" }
        )

        return SCIMGroup(
            id: groupID.uuidString,
            externalId: externalId,
            meta: meta,
            displayName: group.name,
            members: members
        )
    }

    private func addMemberToGroup(userID: UUID, groupID: UUID) async throws {
        // Check if user is in this organization
        let userInOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first() != nil

        guard userInOrg else {
            // User not in organization - log and skip
            db.logger.warning("SCIM Group membership add skipped: user \(userID) is not in organization \(organizationID) for group \(groupID)")
            return
        }

        // Check if already a member
        let existingMembership = try await App.UserGroup.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$group.$id == groupID)
            .first()

        if existingMembership == nil {
            let membership = App.UserGroup(userID: userID, groupID: groupID)
            try await membership.save(on: db)

            // Add to SpiceDB
            try await spicedb.addUserToGroup(
                userID: userID.uuidString,
                groupID: groupID.uuidString
            )
        }
    }

    private func removeMemberFromGroup(userID: UUID, groupID: UUID) async throws {
        try await App.UserGroup.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$group.$id == groupID)
            .delete()

        // Remove from SpiceDB
        try await spicedb.removeUserFromGroup(
            userID: userID.uuidString,
            groupID: groupID.uuidString
        )
    }

    private func removeAllMembersFromGroup(groupID: UUID) async throws {
        let members = try await App.UserGroup.query(on: db)
            .filter(\.$group.$id == groupID)
            .all()

        for member in members {
            try await spicedb.removeUserFromGroup(
                userID: member.$user.id.uuidString,
                groupID: groupID.uuidString
            )
        }

        try await App.UserGroup.query(on: db)
            .filter(\.$group.$id == groupID)
            .delete()
    }

    private func applyPatchOperation(_ operation: SCIMPatchOperation, to group: App.Group, groupID: UUID) async throws {
        guard let path = operation.path else {
            // No path - apply to root object
            if let value = operation.value {
                switch operation.op {
                case .add, .replace:
                    if case .object(let dict) = value {
                        if let displayName = dict["displayName"], case .string(let name) = displayName {
                            group.name = name
                        }
                    }
                case .remove:
                    break
                }
            }
            return
        }

        let lowercasePath = path.lowercased()

        switch lowercasePath {
        case "displayname":
            if let value = operation.value, case .string(let name) = value {
                switch operation.op {
                case .add, .replace:
                    group.name = name
                case .remove:
                    break // Can't remove displayName
                }
            }

        case "members":
            switch operation.op {
            case .add:
                if let value = operation.value {
                    let memberIDs = extractMemberIDs(from: value)
                    for memberID in memberIDs {
                        try await addMemberToGroup(userID: memberID, groupID: groupID)
                    }
                }

            case .remove:
                if let value = operation.value {
                    let memberIDs = extractMemberIDs(from: value)
                    for memberID in memberIDs {
                        try await removeMemberFromGroup(userID: memberID, groupID: groupID)
                    }
                } else {
                    // Remove all members
                    try await removeAllMembersFromGroup(groupID: groupID)
                }

            case .replace:
                try await removeAllMembersFromGroup(groupID: groupID)
                if let value = operation.value {
                    let memberIDs = extractMemberIDs(from: value)
                    for memberID in memberIDs {
                        try await addMemberToGroup(userID: memberID, groupID: groupID)
                    }
                }
            }

        default:
            // Check for members[value eq "..."] path (member removal by value)
            if lowercasePath.hasPrefix("members[") {
                // Parse the filter to get the member ID
                // Format: members[value eq "uuid"]
                if let match = lowercasePath.range(of: "value eq \"", options: .caseInsensitive),
                   let endQuote = lowercasePath.range(of: "\"", range: match.upperBound..<lowercasePath.endIndex)
                {
                    let memberIDString = String(lowercasePath[match.upperBound..<endQuote.lowerBound])
                    if let memberID = UUID(uuidString: memberIDString) {
                        switch operation.op {
                        case .remove:
                            try await removeMemberFromGroup(userID: memberID, groupID: groupID)
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    private func extractMemberIDs(from value: SCIMPatchValue) -> [UUID] {
        var memberIDs: [UUID] = []

        switch value {
        case .array(let items):
            for item in items {
                if case .object(let dict) = item,
                   let valueField = dict["value"],
                   case .string(let idString) = valueField,
                   let uuid = UUID(uuidString: idString)
                {
                    memberIDs.append(uuid)
                }
            }
        case .object(let dict):
            if let valueField = dict["value"],
               case .string(let idString) = valueField,
               let uuid = UUID(uuidString: idString)
            {
                memberIDs.append(uuid)
            }
        default:
            break
        }

        return memberIDs
    }

    private func applyFilter(_ filter: SCIMFilterExpression, to query: QueryBuilder<App.Group>) throws -> QueryBuilder<App.Group> {
        switch filter {
        case .attribute(let path, let op, let value):
            return try applyAttributeFilter(path: path, op: op, value: value, to: query)

        case .logical(let logicalOp, let left, let right):
            switch logicalOp {
            case .and:
                var result = try applyFilter(left, to: query)
                result = try applyFilter(right, to: result)
                return result
            case .or, .not:
                throw SCIMServerError.invalidFilter(
                    detail: "SCIM logical filter operator '\(logicalOp)' is not supported"
                )
            }

        case .not:
            throw SCIMServerError.invalidFilter(
                detail: "SCIM NOT filter is not supported"
            )

        case .present(let path):
            if path.lowercased() == "displayname" {
                return query.filter(\.$name != "")
            }
            return query

        case .group(let inner):
            return try applyFilter(inner, to: query)

        case .empty:
            return query
        }
    }

    private func applyAttributeFilter(
        path: String,
        op: SCIMFilterOperator,
        value: String,
        to query: QueryBuilder<App.Group>
    ) throws -> QueryBuilder<App.Group> {
        let lowercasePath = path.lowercased()

        switch lowercasePath {
        case "displayname":
            return applyStringFilter(keyPath: \App.Group.$name, op: op, value: value, to: query)

        case "externalid":
            // Would need to join with scim_external_ids
            return query

        default:
            return query
        }
    }

    /// Escape special characters used in SQL LIKE/ILIKE patterns.
    /// This prevents user input from injecting unintended wildcards.
    private func escapeLikePattern(_ value: String) -> String {
        var escaped = value
        // First escape the escape character itself
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        // Then escape wildcard characters
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return escaped
    }

    private func applyStringFilter(
        keyPath: KeyPath<App.Group, FieldProperty<App.Group, String>>,
        op: SCIMFilterOperator,
        value: String,
        to query: QueryBuilder<App.Group>
    ) -> QueryBuilder<App.Group> {
        switch op {
        case .equal:
            return query.filter(keyPath == value)
        case .notEqual:
            return query.filter(keyPath != value)
        case .contains:
            let escapedValue = escapeLikePattern(value)
            return query.filter(keyPath, .custom("ILIKE"), "%\(escapedValue)%")
        case .startsWith:
            let escapedValue = escapeLikePattern(value)
            return query.filter(keyPath, .custom("ILIKE"), "\(escapedValue)%")
        case .endsWith:
            let escapedValue = escapeLikePattern(value)
            return query.filter(keyPath, .custom("ILIKE"), "%\(escapedValue)")
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .present:
            return query
        }
    }
}
