import Foundation

// MARK: - User Operations
extension SCIMClient {
    
    /// Create a new user
    /// - Parameter user: The user to create
    /// - Returns: The created user with server-generated fields
    public func createUser(_ user: SCIMUser) async throws -> SCIMUser {
        return try await post(
            path: "Users",
            body: user,
            responseType: SCIMUser.self
        )
    }
    
    /// Get a user by ID
    /// - Parameter id: The user ID
    /// - Returns: The user if found
    public func getUser(id: String) async throws -> SCIMUser {
        return try await get(
            path: "Users/\(id)",
            responseType: SCIMUser.self
        )
    }
    
    /// Get users with optional query parameters
    /// - Parameter queryParameters: Query parameters for filtering, sorting, and pagination
    /// - Returns: List response containing users
    public func getUsers(queryParameters: SCIMQueryParameters? = nil) async throws -> SCIMListResponse<SCIMUser> {
        return try await get(
            path: "Users",
            queryParameters: queryParameters,
            responseType: SCIMListResponse<SCIMUser>.self
        )
    }
    
    /// Update a user completely (PUT)
    /// - Parameters:
    ///   - id: The user ID
    ///   - user: The updated user
    /// - Returns: The updated user
    public func updateUser(id: String, user: SCIMUser) async throws -> SCIMUser {
        var updatedUser = user
        // Ensure the ID matches the path parameter
        if updatedUser.id != id {
            // Create a new user with the correct ID
            updatedUser = SCIMUser(
                id: id,
                externalId: user.externalId,
                meta: user.meta,
                userName: user.userName,
                name: user.name,
                displayName: user.displayName,
                nickName: user.nickName,
                profileUrl: user.profileUrl,
                title: user.title,
                userType: user.userType,
                preferredLanguage: user.preferredLanguage,
                locale: user.locale,
                timezone: user.timezone,
                active: user.active,
                password: user.password,
                emails: user.emails,
                phoneNumbers: user.phoneNumbers,
                ims: user.ims,
                photos: user.photos,
                addresses: user.addresses,
                groups: user.groups,
                entitlements: user.entitlements,
                roles: user.roles,
                x509Certificates: user.x509Certificates
            )
        }
        
        return try await put(
            path: "Users/\(id)",
            body: updatedUser,
            responseType: SCIMUser.self
        )
    }
    
    /// Partially update a user (PATCH)
    /// - Parameters:
    ///   - id: The user ID
    ///   - patchRequest: The patch operations to apply
    /// - Returns: The updated user
    public func patchUser(id: String, patchRequest: SCIMPatchRequest) async throws -> SCIMUser {
        return try await patch(
            path: "Users/\(id)",
            body: patchRequest,
            responseType: SCIMUser.self
        )
    }
    
    /// Delete a user
    /// - Parameter id: The user ID
    public func deleteUser(id: String) async throws {
        try await delete(path: "Users/\(id)")
    }
    
    /// Search users with a filter
    /// - Parameter filter: The SCIM filter to apply
    /// - Returns: List response containing matching users
    public func searchUsers(filter: SCIMFilter) async throws -> SCIMListResponse<SCIMUser> {
        let queryParameters = SCIMQueryParameters(filter: filter)
        return try await getUsers(queryParameters: queryParameters)
    }
    
    /// Search users using the filter DSL
    /// - Parameter filterBuilder: The filter builder closure
    /// - Returns: List response containing matching users
    public func searchUsers(@SCIMFilterBuilder _ filterBuilder: () -> SCIMFilterExpression) async throws -> SCIMListResponse<SCIMUser> {
        let filter = SCIMFilter(filterBuilder().stringValue)
        return try await searchUsers(filter: filter)
    }
    
    /// Find users by username
    /// - Parameter userName: The username to search for
    /// - Returns: List response containing matching users
    public func findUsersByUsername(_ userName: String) async throws -> SCIMListResponse<SCIMUser> {
        return try await searchUsers {
            SCIMFilterDSL.eq("userName", userName)
        }
    }
    
    /// Find users by email
    /// - Parameter email: The email to search for
    /// - Returns: List response containing matching users
    public func findUsersByEmail(_ email: String) async throws -> SCIMListResponse<SCIMUser> {
        return try await searchUsers {
            SCIMFilterDSL.eq("emails.value", email)
        }
    }
    
    /// Find active users
    /// - Returns: List response containing active users
    public func findActiveUsers() async throws -> SCIMListResponse<SCIMUser> {
        return try await searchUsers {
            SCIMFilterDSL.eq("active", "true")
        }
    }
    
    /// Get all users with pagination
    /// - Parameters:
    ///   - startIndex: The starting index (1-based)
    ///   - count: The number of results to return
    /// - Returns: List response containing users
    public func getAllUsers(startIndex: Int = 1, count: Int = 100) async throws -> SCIMListResponse<SCIMUser> {
        let queryParameters = SCIMQueryParameters(
            startIndex: startIndex,
            count: count
        )
        return try await getUsers(queryParameters: queryParameters)
    }
}