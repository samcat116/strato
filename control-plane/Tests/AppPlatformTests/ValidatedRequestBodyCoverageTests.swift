import Foundation
import Testing

/// STR-256's structural guard: `decodeValidated` makes conformance a compiler
/// requirement, and this source-level check makes bypassing it visible.
struct ValidatedRequestBodyCoverageTests {
    /// Request bodies that legitimately do not use the generic text ceilings.
    /// Keeping the file in the key disambiguates controller-local DTO names.
    private static let plainDecodeOptOuts: [String: String] = [
        "Controllers/AgentController.swift:CreateAgentEnrollmentRequest":
            "agentName has the SPIFFE path-segment grammar enforced by the DTO",
        "Controllers/FloatingIPController.swift:CreateFloatingIPRequest":
            "identifiers only",
        "Controllers/FloatingIPController.swift:UpdateFloatingIPPoolRequest":
            "gateway grammar and a site identifier only",
        "Controllers/LoadBalancerController.swift:CreateLoadBalancerBackendRequest":
            "identifiers and an IP-address grammar only",
        "Controllers/LoadBalancerController.swift:CreateLoadBalancerListenerRequest":
            "bounded integer ports only",
        "Controllers/LoadBalancerController.swift:UpdateLoadBalancerListenerRequest":
            "bounded integer ports only",
        "Controllers/OIDCController.swift:CreateOIDCProviderRequest":
            "OIDC protocol configuration has its own validators",
        "Controllers/OIDCController.swift:UpdateOIDCProviderRequest":
            "OIDC protocol configuration has its own validators",
        "Controllers/OrganizationController.swift:UpdateRoleRequest":
            "a role identifier only",
        "Controllers/OrganizationalUnitMemberController.swift:UpdateMemberRoleRequest":
            "a role identifier only",
        "Controllers/ProjectMemberController.swift:UpdateMemberRoleRequest":
            "a role identifier only",
        "Controllers/ServiceAccountController.swift:CreateRegistrationRequest":
            "spiffeId has the workload-registration grammar",
        "Controllers/UserController.swift:CreateUserRequest":
            "the account endpoint applies username, email, and display-name grammars",
        "Controllers/UserController.swift:UpdateUserRequest":
            "the account endpoint applies username, email, and display-name grammars",
        "Controllers/VMController.swift:CreateVMNetworkInterfaceRequest":
            "network selection and MTU have dedicated validation",
    ]

    @Test("Create and update request handlers cannot silently bypass validation")
    func createAndUpdateRequestsUseValidatedDecodeOrAnExplicitOptOut() throws {
        let plainDecodePattern = try NSRegularExpression(
            pattern: #"\.content\.decode\(\s*((?:Create|Update)\w*Request)\.self\s*\)"#
        )
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppPlatformTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // control-plane
            .appendingPathComponent("Sources/App")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: appSources, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        )

        var plainDecodes: Set<String> = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = fileURL.path.replacingOccurrences(
                of: appSources.path + "/", with: "")
            let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in plainDecodePattern.matches(in: source, range: sourceRange) {
                let typeRange = try #require(Range(match.range(at: 1), in: source))
                let typeName = String(source[typeRange])
                plainDecodes.insert("\(relativePath):\(typeName)")
            }
        }

        let optOuts = Set(Self.plainDecodeOptOuts.keys)
        #expect(
            plainDecodes == optOuts,
            """
            Plain create/update request decoding drifted.
            Unreviewed bypasses: \(plainDecodes.subtracting(optOuts).sorted())
            Stale opt-outs: \(optOuts.subtracting(plainDecodes).sorted())
            """)
    }
}
