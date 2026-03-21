// SwiftSCIM - A Swift client library for SCIM (System for Cross-domain Identity Management)
// Copyright (c) 2024

import Foundation

/// SwiftSCIM provides a complete Swift client implementation for SCIM 2.0
/// 
/// Key features:
/// - Type-safe SCIM resource models (User, Group)
/// - Async/await API with modern Swift concurrency
/// - Comprehensive filter DSL with result builders
/// - Authentication providers (Bearer token, OAuth2, custom)
/// - Full CRUD operations for users and groups
/// - Search functionality with pagination
/// - PATCH operations support
/// - Bulk operations
/// - Service discovery (schemas, resource types, configuration)
/// - Thread-safe design with Sendable conformance
///
/// Example usage:
/// ```swift
/// let client = SCIMClient(
///     baseURL: URL(string: "https://api.example.com/scim/v2")!,
///     authenticationProvider: BearerTokenAuthenticationProvider(token: "your-token")
/// )
/// 
/// // Create a user
/// let user = SCIMUser(userName: "john.doe", displayName: "John Doe")
/// let createdUser = try await client.createUser(user)
/// 
/// // Search for users
/// let users = try await client.searchUsers {
///     SCIMFilterDSL.eq("emails.value", "john@example.com")
/// }
/// ```
public struct SwiftSCIM {
    /// Library version
    public static let version = "1.0.0"
}
