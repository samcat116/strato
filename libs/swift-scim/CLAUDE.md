# CLAUDE.md

## Project Overview

SwiftSCIM is a Swift client library for SCIM (System for Cross-domain Identity Management) 2.0. It provides type-safe models and an async/await API for interacting with SCIM-compliant identity provider endpoints. It implements RFC 7642, 7643, and 7644. This is a library (not an application) -- it has no executable target.

## Build / Test

```bash
swift build
swift test
```

- Swift Package Manager is the build system (Package.swift)
- Requires Swift 6.1+ with strict concurrency checking (swift-tools-version: 6.1)
- Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+
- No external dependencies -- only Foundation and URLSession

## Project Structure

```
Sources/SwiftSCIM/
  SwiftSCIM.swift                    # Library entry point, version constant
  Client/
    SCIMClient.swift                 # Core actor: HTTP transport, JSON coding, request execution
    SCIMClient+Users.swift           # Extension: user CRUD, search, and convenience methods
    SCIMClient+Groups.swift          # Extension: group CRUD, membership management
    SCIMClient+Search.swift          # Extension: cross-resource search, bulk ops, service discovery
  Models/
    SCIMResource.swift               # SCIMResource protocol, SCIMResourceMeta, SCIMMultiValuedAttribute<T>, SCIMListResponse<T>
    SCIMUser.swift                   # SCIMUser, UserName, UserAddress, UserGroup
    SCIMGroup.swift                  # SCIMGroup, GroupMember
    SCIMPatch.swift                  # SCIMPatchRequest, SCIMPatchOperation, SCIMPatchValue enum
    SCIMServiceProvider.swift        # Service provider config, bulk/filter configs, resource types, schemas, bulk request/response
  Filters/
    SCIMFilter.swift                 # Filter DSL: SCIMFilter, SCIMFilterBuilder (@resultBuilder), SCIMFilterDSL, SCIMQueryParameters
  Errors/
    SCIMError.swift                  # SCIMClientError enum, SCIMErrorResponse, SCIMErrorType
  Authentication/
    SCIMAuthentication.swift         # SCIMAuthenticationProvider protocol, BearerToken/OAuth2/Custom providers
Tests/SwiftSCIMTests/
  SwiftSCIMTests.swift              # Unit tests using Swift Testing framework (@Test, #expect)
```

## Architecture

- **`SCIMClient` is an `actor`** -- all client methods are isolated. Callers must use `await`.
- The client is extended via files using `extension SCIMClient` grouped by domain (Users, Groups, Search).
- Internal HTTP helpers (`get`, `post`, `put`, `patch`, `delete`) are `internal` methods on the actor; public API methods in extensions call these.
- All model types conform to `Codable` and `Sendable`. The `SCIMResource` protocol defines the shared interface (`id`, `externalId`, `meta`, `schemas`).
- Authentication uses a protocol (`SCIMAuthenticationProvider`) with three concrete implementations: `BearerTokenAuthenticationProvider` (actor), `OAuth2AuthenticationProvider` (actor), and `CustomAuthenticationProvider` (struct with closures).
- SCIM filter construction uses a `@resultBuilder` (`SCIMFilterBuilder`) and a DSL helper (`SCIMFilterDSL`) with static methods like `.eq()`, `.co()`, `.and()`, `.or()`.
- JSON encoding/decoding uses ISO 8601 dates with fractional seconds via custom strategies on `JSONEncoder`/`JSONDecoder`.
- SCIM content type is `application/scim+json` for both Accept and Content-Type headers.

## Coding Conventions

- **4-space indentation**
- **`public` access** for all API-facing types, properties, and methods; `internal` for transport helpers; `private` for implementation details
- **Doc comments** (`///`) on all public types and methods, using Swift-style parameter documentation
- **MARK comments** (`// MARK: -`) to separate logical sections within extension files
- **Immutable by default**: model properties are `let` except where mutation is needed (`externalId` is `var` on `SCIMResource`)
- **Optional parameters** with `nil` defaults in initializers -- models mirror SCIM's schema where most fields are optional
- **Static factory methods** for convenience constructors (e.g., `SCIMPatchOperation.add(path:value:)`, `SCIMPatchRequest.setUserActive(_:)`)
- **SCIM schema URIs** are hardcoded as string literals in each model's `init` (e.g., `"urn:ietf:params:scim:schemas:core:2.0:User"`)
- **CodingKeys** used only when JSON key differs from Swift property name (e.g., `$ref` mapped to `ref`)
- **SCIM list responses** use capital-R `Resources` property name to match the SCIM JSON wire format
- Tests use Swift Testing framework (`import Testing`, `@Test` functions, `#expect` macro) -- not XCTest

## Key Types to Know

| Type | Role |
|------|------|
| `SCIMClient` | Main entry point (actor); holds baseURL, auth provider, URLSession |
| `SCIMUser` / `SCIMGroup` | Core SCIM resource models |
| `SCIMPatchRequest` / `SCIMPatchOperation` | PATCH operation construction |
| `SCIMFilterDSL` / `SCIMFilterBuilder` | Filter query construction |
| `SCIMQueryParameters` | Wraps filter, pagination, sorting, attribute selection |
| `SCIMClientError` | Comprehensive error enum with `LocalizedError` conformance |
| `SCIMAuthenticationProvider` | Protocol for pluggable auth |
| `AnyCodable` | Type-erased Codable for mixed search results (`SCIMGenericResource`) |
