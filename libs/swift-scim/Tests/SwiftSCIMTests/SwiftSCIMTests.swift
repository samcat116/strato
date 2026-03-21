import Testing
import Foundation
@testable import SwiftSCIM

@Test func libraryVersion() {
    #expect(SwiftSCIM.version == "1.0.0")
}

@Test func scimUserCreation() {
    let user = SCIMUser(userName: "testuser")
    #expect(user.userName == "testuser")
    #expect(user.schemas.first == "urn:ietf:params:scim:schemas:core:2.0:User")
}

@Test func scimGroupCreation() {
    let group = SCIMGroup(displayName: "Test Group")
    #expect(group.displayName == "Test Group")
    #expect(group.schemas.first == "urn:ietf:params:scim:schemas:core:2.0:Group")
}

@Test func scimFilterBuilding() {
    let filter = SCIMFilterDSL.filter {
        SCIMFilterDSL.eq("userName", "testuser")
    }
    #expect(filter.expression == "userName eq \"testuser\"")
}

@Test func complexSCIMFilter() {
    let filter = SCIMFilterDSL.filter {
        SCIMFilterDSL.and(
            SCIMFilterDSL.eq("active", "true"),
            SCIMFilterDSL.co("emails.value", "@example.com")
        )
    }
    #expect(filter.expression == "(active eq \"true\" and emails.value co \"@example.com\")")
}

@Test func scimUserWithMultiValuedAttributes() {
    let emails = [
        SCIMMultiValuedAttribute(value: "primary@example.com", type: "work", primary: true),
        SCIMMultiValuedAttribute(value: "secondary@example.com", type: "personal", primary: false)
    ]
    
    let user = SCIMUser(
        userName: "testuser",
        displayName: "Test User",
        emails: emails
    )
    
    #expect(user.emails?.count == 2)
    #expect(user.emails?.first?.value == "primary@example.com")
    #expect(user.emails?.first?.primary == true)
}

@Test func scimPatchOperations() {
    let patchRequest = SCIMPatchRequest(operations: [
        .replace(path: "active", boolValue: false),
        .add(path: "displayName", stringValue: "Updated Name")
    ])
    
    #expect(patchRequest.Operations.count == 2)
    #expect(patchRequest.Operations[0].op == .replace)
    #expect(patchRequest.Operations[1].op == .add)
}

@Test func scimQueryParameters() {
    let queryParams = SCIMQueryParameters(
        filter: SCIMFilter("userName eq \"test\""),
        attributes: ["userName", "displayName"],
        startIndex: 1,
        count: 10
    )
    
    let queryItems = queryParams.queryItems
    #expect(queryItems.contains { $0.name == "filter" && $0.value == "userName eq \"test\"" })
    #expect(queryItems.contains { $0.name == "attributes" && $0.value == "userName,displayName" })
    #expect(queryItems.contains { $0.name == "startIndex" && $0.value == "1" })
    #expect(queryItems.contains { $0.name == "count" && $0.value == "10" })
}

@Test func scimClientInitialization() async {
    let baseURL = URL(string: "https://api.example.com/scim/v2")!
    let authProvider = await BearerTokenAuthenticationProvider(token: "test-token")
    
    let client = SCIMClient(
        baseURL: baseURL,
        authenticationProvider: authProvider
    )
    
    #expect(client != nil)
}

@Test func bearerTokenAuthentication() async throws {
    let authProvider = await BearerTokenAuthenticationProvider(token: "test-token")
    let isValid = await authProvider.isValid
    #expect(isValid == true)
    
    var request = URLRequest(url: URL(string: "https://example.com")!)
    try await authProvider.authenticate(request: &request)
    
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
}

@Test func scimErrorTypes() {
    let error = SCIMClientError.resourceNotFound
    #expect(error.localizedDescription == "Resource not found")
}
