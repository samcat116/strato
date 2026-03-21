import Foundation

// MARK: - Group Operations
extension SCIMClient {
    
    /// Create a new group
    /// - Parameter group: The group to create
    /// - Returns: The created group with server-generated fields
    public func createGroup(_ group: SCIMGroup) async throws -> SCIMGroup {
        return try await post(
            path: "Groups",
            body: group,
            responseType: SCIMGroup.self
        )
    }
    
    /// Get a group by ID
    /// - Parameter id: The group ID
    /// - Returns: The group if found
    public func getGroup(id: String) async throws -> SCIMGroup {
        return try await get(
            path: "Groups/\(id)",
            responseType: SCIMGroup.self
        )
    }
    
    /// Get groups with optional query parameters
    /// - Parameter queryParameters: Query parameters for filtering, sorting, and pagination
    /// - Returns: List response containing groups
    public func getGroups(queryParameters: SCIMQueryParameters? = nil) async throws -> SCIMListResponse<SCIMGroup> {
        return try await get(
            path: "Groups",
            queryParameters: queryParameters,
            responseType: SCIMListResponse<SCIMGroup>.self
        )
    }
    
    /// Update a group completely (PUT)
    /// - Parameters:
    ///   - id: The group ID
    ///   - group: The updated group
    /// - Returns: The updated group
    public func updateGroup(id: String, group: SCIMGroup) async throws -> SCIMGroup {
        var updatedGroup = group
        // Ensure the ID matches the path parameter
        if updatedGroup.id != id {
            // Create a new group with the correct ID
            updatedGroup = SCIMGroup(
                id: id,
                externalId: group.externalId,
                meta: group.meta,
                displayName: group.displayName,
                members: group.members
            )
        }
        
        return try await put(
            path: "Groups/\(id)",
            body: updatedGroup,
            responseType: SCIMGroup.self
        )
    }
    
    /// Partially update a group (PATCH)
    /// - Parameters:
    ///   - id: The group ID
    ///   - patchRequest: The patch operations to apply
    /// - Returns: The updated group
    public func patchGroup(id: String, patchRequest: SCIMPatchRequest) async throws -> SCIMGroup {
        return try await patch(
            path: "Groups/\(id)",
            body: patchRequest,
            responseType: SCIMGroup.self
        )
    }
    
    /// Delete a group
    /// - Parameter id: The group ID
    public func deleteGroup(id: String) async throws {
        try await delete(path: "Groups/\(id)")
    }
    
    /// Search groups with a filter
    /// - Parameter filter: The SCIM filter to apply
    /// - Returns: List response containing matching groups
    public func searchGroups(filter: SCIMFilter) async throws -> SCIMListResponse<SCIMGroup> {
        let queryParameters = SCIMQueryParameters(filter: filter)
        return try await getGroups(queryParameters: queryParameters)
    }
    
    /// Search groups using the filter DSL
    /// - Parameter filterBuilder: The filter builder closure
    /// - Returns: List response containing matching groups
    public func searchGroups(@SCIMFilterBuilder _ filterBuilder: () -> SCIMFilterExpression) async throws -> SCIMListResponse<SCIMGroup> {
        let filter = SCIMFilter(filterBuilder().stringValue)
        return try await searchGroups(filter: filter)
    }
    
    /// Find groups by display name
    /// - Parameter displayName: The display name to search for
    /// - Returns: List response containing matching groups
    public func findGroupsByDisplayName(_ displayName: String) async throws -> SCIMListResponse<SCIMGroup> {
        return try await searchGroups {
            SCIMFilterDSL.eq("displayName", displayName)
        }
    }
    
    /// Find groups that contain a specific user
    /// - Parameter userId: The user ID to search for
    /// - Returns: List response containing groups with the user as a member
    public func findGroupsWithUser(_ userId: String) async throws -> SCIMListResponse<SCIMGroup> {
        return try await searchGroups {
            SCIMFilterDSL.eq("members.value", userId)
        }
    }
    
    /// Get all groups with pagination
    /// - Parameters:
    ///   - startIndex: The starting index (1-based)
    ///   - count: The number of results to return
    /// - Returns: List response containing groups
    public func getAllGroups(startIndex: Int = 1, count: Int = 100) async throws -> SCIMListResponse<SCIMGroup> {
        let queryParameters = SCIMQueryParameters(
            startIndex: startIndex,
            count: count
        )
        return try await getGroups(queryParameters: queryParameters)
    }
    
    /// Add a user to a group
    /// - Parameters:
    ///   - groupId: The group ID
    ///   - userId: The user ID to add
    ///   - userDisplayName: Optional display name for the user
    /// - Returns: The updated group
    public func addUserToGroup(groupId: String, userId: String, userDisplayName: String? = nil) async throws -> SCIMGroup {
        var memberObject: [String: SCIMPatchValue] = [
            "value": .string(userId)
        ]
        
        if let displayName = userDisplayName {
            memberObject["display"] = .string(displayName)
        }
        
        let patchRequest = SCIMPatchRequest(
            operation: .add(
                path: "members",
                value: .array([.object(memberObject)])
            )
        )
        
        return try await patchGroup(id: groupId, patchRequest: patchRequest)
    }
    
    /// Remove a user from a group
    /// - Parameters:
    ///   - groupId: The group ID
    ///   - userId: The user ID to remove
    /// - Returns: The updated group
    public func removeUserFromGroup(groupId: String, userId: String) async throws -> SCIMGroup {
        let patchRequest = SCIMPatchRequest(
            operation: .remove(path: "members[value eq \"\(userId)\"]")
        )
        
        return try await patchGroup(id: groupId, patchRequest: patchRequest)
    }
}