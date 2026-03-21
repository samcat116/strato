# SwiftSCIM

A Swift client library for SCIM (System for Cross-domain Identity Management) 2.0 designed for safety, performance, and modern Swift concurrency.

## Features

- **Type-safe SCIM models** - Codable structs for User, Group, and all SCIM attributes
- **Modern async/await API** - Built with Swift concurrency from the ground up
- **Comprehensive filtering** - Result builder DSL for constructing SCIM filters
- **Flexible authentication** - Bearer token, OAuth2, and custom authentication providers
- **Full CRUD operations** - Complete support for creating, reading, updating, and deleting users and groups
- **Search & pagination** - Advanced search with filtering, sorting, and pagination
- **PATCH operations** - Partial updates with type-safe PATCH operations
- **Bulk operations** - Efficient batch operations for multiple resources
- **Service discovery** - Query schemas, resource types, and service provider configuration
- **Thread-safe design** - All types conform to Sendable for safe concurrent usage
- **Framework agnostic** - Works with any Swift project, not tied to specific web frameworks

## Requirements

- Swift 6.1+
- iOS 16.0+ / macOS 13.0+ / tvOS 16.0+ / watchOS 9.0+

## Installation

### Swift Package Manager

Add SwiftSCIM to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/yourorg/swift-scim.git", from: "1.0.0")
]
```

Or add it through Xcode: File → Add Package Dependencies

## Usage

### Basic Setup

```swift
import SwiftSCIM

// Create a client with authentication
let client = SCIMClient(
    baseURL: URL(string: "https://api.example.com/scim/v2")!,
    authenticationProvider: BearerTokenAuthenticationProvider(token: "your-access-token")
)
```

### Authentication

#### Bearer Token
```swift
let authProvider = BearerTokenAuthenticationProvider(token: "your-token")
```

#### OAuth 2.0
```swift
let authProvider = OAuth2AuthenticationProvider(
    accessToken: "access-token",
    refreshToken: "refresh-token",
    clientId: "your-client-id",
    clientSecret: "your-client-secret",
    tokenEndpoint: URL(string: "https://auth.example.com/token")!
)
```

#### Custom Authentication
```swift
let authProvider = CustomAuthenticationProvider { request in
    request.setValue("Custom auth-header", forHTTPHeaderField: "Authorization")
}
```

### User Operations

#### Create a User
```swift
let user = SCIMUser(
    userName: "john.doe",
    displayName: "John Doe",
    emails: [
        SCIMMultiValuedAttribute(value: "john@example.com", type: "work", primary: true)
    ],
    active: true
)

let createdUser = try await client.createUser(user)
```

#### Get a User
```swift
let user = try await client.getUser(id: "user-id")
```

#### Update a User
```swift
var updatedUser = user
updatedUser.displayName = "John Smith"
let result = try await client.updateUser(id: user.id!, user: updatedUser)
```

#### Patch a User
```swift
let patch = SCIMPatchRequest.setUserActive(false)
let updatedUser = try await client.patchUser(id: "user-id", patchRequest: patch)
```

#### Delete a User
```swift
try await client.deleteUser(id: "user-id")
```

### Search and Filtering

#### Simple Search
```swift
let users = try await client.findUsersByEmail("john@example.com")
```

#### Advanced Filtering with DSL
```swift
let users = try await client.searchUsers {
    SCIMFilterDSL.and(
        SCIMFilterDSL.eq("active", "true"),
        SCIMFilterDSL.or(
            SCIMFilterDSL.co("emails.value", "@example.com"),
            SCIMFilterDSL.eq("userType", "Employee")
        )
    )
}
```

#### Pagination
```swift
let users = try await client.getAllUsers(startIndex: 1, count: 50)
```

### Group Operations

#### Create a Group
```swift
let group = SCIMGroup(displayName: "Developers")
let createdGroup = try await client.createGroup(group)
```

#### Add User to Group
```swift
let updatedGroup = try await client.addUserToGroup(
    groupId: "group-id",
    userId: "user-id",
    userDisplayName: "John Doe"
)
```

#### Remove User from Group
```swift
let updatedGroup = try await client.removeUserFromGroup(
    groupId: "group-id",
    userId: "user-id"
)
```

### Service Discovery

#### Get Service Provider Configuration
```swift
let config = try await client.getServiceProviderConfig()
print("Bulk operations supported: \\(config.bulk.supported)")
```

#### Get Resource Types
```swift
let resourceTypes = try await client.getResourceTypes()
```

#### Get Schemas
```swift
let schemas = try await client.getSchemas()
```

### Error Handling

```swift
do {
    let user = try await client.getUser(id: "nonexistent")
} catch SCIMClientError.resourceNotFound {
    print("User not found")
} catch SCIMClientError.authenticationFailed {
    print("Authentication failed")
} catch let SCIMClientError.scimError(errorResponse) {
    print("SCIM error: \\(errorResponse.detail ?? "Unknown")")
} catch {
    print("Other error: \\(error)")
}
```

## Integration with Vapor

While SwiftSCIM is framework-agnostic, here's an example of using it in a Vapor application:

```swift
import Vapor
import SwiftSCIM

// Configure SCIM client
app.scim.client = SCIMClient(
    baseURL: URL(string: Environment.get("SCIM_BASE_URL")!)!,
    authenticationProvider: BearerTokenAuthenticationProvider(
        token: Environment.get("SCIM_TOKEN")!
    )
)

// Use in route handlers
app.post("users") { req async throws -> SCIMUser in
    let createUserRequest = try req.content.decode(CreateUserRequest.self)
    
    let user = SCIMUser(userName: createUserRequest.username)
    return try await req.application.scim.client.createUser(user)
}
```

## Testing

Run the test suite:

```bash
swift test
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## SCIM Specification

This library implements the SCIM 2.0 specification as defined in:
- [RFC 7642: SCIM: Definitions, Overview, Concepts, and Requirements](https://datatracker.ietf.org/doc/html/rfc7642)
- [RFC 7643: SCIM: Core Schema](https://datatracker.ietf.org/doc/html/rfc7643)  
- [RFC 7644: SCIM: Protocol](https://datatracker.ietf.org/doc/html/rfc7644)