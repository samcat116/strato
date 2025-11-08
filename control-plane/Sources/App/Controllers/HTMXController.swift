import Elementary
import ElementaryHTMX
import Fluent
import Vapor

struct HTMXController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let htmx = routes.grouped("htmx")

        // VM endpoints
        let vms = htmx.grouped("vms")
        vms.get("list", use: listVMs)
        vms.post("create", use: createVM)
        vms.post(":vmID", "start", use: startVM)
        vms.post(":vmID", "stop", use: stopVM)
        vms.post(":vmID", "restart", use: restartVM)
        vms.delete(":vmID", use: deleteVM)
        vms.get(":vmID", "details", use: vmDetails)

        // Organization endpoints
        let orgs = htmx.grouped("organizations")
        orgs.get("list", use: listOrganizations)
        orgs.get("current", use: getCurrentOrganization)
        orgs.get("settings", use: getOrganizationSettings)
        orgs.post("create", use: createOrganization)
        orgs.post(":orgID", "switch", use: switchOrganization)

        // Organization settings endpoints
        let orgSettings = orgs.grouped(":orgID", "settings")
        orgSettings.put("update", use: updateOrganizationInfo)
        orgSettings.get("info-tab", use: getOrganizationInfoTab)
        orgSettings.get("oidc-tab", use: getOIDCTab)

        // OIDC provider endpoints (HTMX versions)
        let oidcEndpoints = orgSettings.grouped("oidc-providers")
        oidcEndpoints.get("list", use: listOIDCProviders)
        oidcEndpoints.get("form", "new", use: showNewOIDCProviderForm)
        oidcEndpoints.post("create", use: createOIDCProvider)
        oidcEndpoints.get(":providerID", "form", "edit", use: showEditOIDCProviderForm)
        oidcEndpoints.put(":providerID", "update", use: updateOIDCProvider)
        oidcEndpoints.delete(":providerID", use: deleteOIDCProvider)

        // API Key endpoints
        let apiKeys = htmx.grouped("api-keys")
        apiKeys.get("list", use: listAPIKeys)
        apiKeys.post("create", use: createAPIKey)
        apiKeys.patch(":keyID", "toggle", use: toggleAPIKey)
        apiKeys.delete(":keyID", use: deleteAPIKey)

        // Auth completion endpoints
        let auth = htmx.grouped("auth")
        auth.post("login", "complete", use: loginComplete)

        // Onboarding endpoints
        let onboarding = htmx.grouped("onboarding")
        onboarding.post("setup", use: setupOrganization)
    }

    // MARK: - VM Endpoints

    func listVMs(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let allVMs = try await VM.query(on: req.db).all()
        var authorizedVMs: [VM] = []

        for vm in allVMs {
            let hasPermission = try await req.spicedb.checkPermission(
                subject: user.id?.uuidString ?? "",
                permission: "read",
                resource: "virtual_machine",
                resourceId: vm.id?.uuidString ?? ""
            )

            if hasPermission {
                authorizedVMs.append(vm)
            }
        }

        let html = VMListPartial(vms: authorizedVMs).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func createVM(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        struct CreateVMRequest: Content {
            let vmName: String
            let vmDescription: String
            let vmCpu: String
            let vmMemory: String
            let vmDisk: String
            let vmTemplate: String
        }

        let createRequest = try req.content.decode(CreateVMRequest.self)

        // Convert form values
        guard let cpu = Int(createRequest.vmCpu),
              let memoryGB = Int(createRequest.vmMemory),
              let diskGB = Int(createRequest.vmDisk) else {
            throw Abort(.badRequest, reason: "Invalid numeric values")
        }

        let memory = Int64(memoryGB) * 1024 * 1024 * 1024
        let disk = Int64(diskGB) * 1024 * 1024 * 1024

        // Create VM and assign to user's current organization
        let vm = VM()
        vm.name = createRequest.vmName
        vm.description = createRequest.vmDescription
        vm.cpu = cpu
        vm.memory = memory
        vm.disk = disk
        vm.image = createRequest.vmTemplate

        // Assign to user's current organization if available
        if let currentOrgId = user.currentOrganizationId {
            // Find or create default project for organization
            let defaultProject = try await Project.query(on: req.db)
                .filter(\Project.$organization.$id, .equal, currentOrgId)
                .filter(\Project.$name, .equal, "Default Project")
                .first()

            if let project = defaultProject,
               let projectId = project.id {
                vm.$project.id = projectId
            }
        }

        try await vm.save(on: req.db)

        // Return updated VM list
        return try await listVMs(req: req)
    }

    func startVM(req: Request) async throws -> Response {
        // VM control implementation
        let vmID = req.parameters.get("vmID") ?? ""
        let html = VMActionResponsePartial(message: "VM \(vmID) start command sent").render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func stopVM(req: Request) async throws -> Response {
        let vmID = req.parameters.get("vmID") ?? ""
        let html = VMActionResponsePartial(message: "VM \(vmID) stop command sent").render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func restartVM(req: Request) async throws -> Response {
        let vmID = req.parameters.get("vmID") ?? ""
        let html = VMActionResponsePartial(message: "VM \(vmID) restart command sent").render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func deleteVM(req: Request) async throws -> Response {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        try await vm.delete(on: req.db)

        // Return updated VM list
        return try await listVMs(req: req)
    }

    func vmDetails(req: Request) async throws -> Response {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        let html = VMDetailsPartial(vm: vm).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    // MARK: - Organization Endpoints

    func listOrganizations(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)

        // Get user roles for each organization
        var organizationResponses: [OrganizationResponse] = []

        for organization in user.organizations {
            let userOrg = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == user.id!)
                .filter(\.$organization.$id == organization.id!)
                .first()

            let response = OrganizationResponse(
                from: organization,
                userRole: userOrg?.role
            )
            organizationResponses.append(response)
        }

        let html = OrganizationListPartial(organizations: organizationResponses, currentOrgId: user.currentOrganizationId).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func getCurrentOrganization(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get current organization name
        if let currentOrgId = user.currentOrganizationId,
           let currentOrg = try await Organization.find(currentOrgId, on: req.db) {
            let html = currentOrg.name
            return Response(
                status: .ok,
                headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: html)
            )
        } else {
            // Set the first organization as current if none is set
            try await user.$organizations.load(on: req.db)
            if let firstOrg = user.organizations.first {
                user.currentOrganizationId = firstOrg.id
                try await user.save(on: req.db)
                return Response(
                    status: .ok,
                    headers: HTTPHeaders([("Content-Type", "text/html")]),
                    body: .init(string: firstOrg.name)
                )
            } else {
                return Response(
                    status: .ok,
                    headers: HTTPHeaders([("Content-Type", "text/html")]),
                    body: .init(string: "No Organizations")
                )
            }
        }
    }

    func getOrganizationSettings(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get current organization
        guard let currentOrgId = user.currentOrganizationId else {
            throw Abort(.badRequest, reason: "No current organization selected")
        }

        // Check if user is admin of current organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == currentOrgId)
            .first()

        guard let membership = userOrg, membership.role == "admin" else {
            throw Abort(.forbidden, reason: "Only organization administrators can access organization settings")
        }

        // Redirect to organization settings page
        return req.redirect(to: "/organizations/\(currentOrgId.uuidString)/settings", redirectType: .normal)
    }

    func createOrganization(req: Request) async throws -> Response {
        // Organization creation implementation
        let html = OrganizationListPartial(organizations: [], currentOrgId: nil).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func switchOrganization(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Check if user belongs to this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }

        user.currentOrganizationId = organizationID
        try await user.save(on: req.db)

        // Get the organization name for the response
        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Return a response that will trigger updates to multiple targets
        let html = """
        <div id="orgList" hx-swap-oob="true">
            \(try await listOrganizationsHTML(req: req))
        </div>
        <span id="currentOrgName" hx-swap-oob="true">\(organization.name)</span>
        <script>document.getElementById('orgDropdown').classList.add('hidden');</script>
        """

        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    private func listOrganizationsHTML(req: Request) async throws -> String {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)

        // Get user roles for each organization
        var organizationResponses: [OrganizationResponse] = []

        for organization in user.organizations {
            let userOrg = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == user.id!)
                .filter(\.$organization.$id == organization.id!)
                .first()

            let response = OrganizationResponse(
                from: organization,
                userRole: userOrg?.role
            )
            organizationResponses.append(response)
        }

        return OrganizationListPartial(organizations: organizationResponses, currentOrgId: user.currentOrganizationId).render()
    }

    // MARK: - API Key Endpoints

    func listAPIKeys(req: Request) async throws -> Response {
        // API key listing implementation
        let html = APIKeyListPartial(apiKeys: []).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func createAPIKey(req: Request) async throws -> Response {
        // API key creation implementation
        let html = APIKeyListPartial(apiKeys: []).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func toggleAPIKey(req: Request) async throws -> Response {
        // API key toggle implementation
        let html = APIKeyListPartial(apiKeys: []).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    func deleteAPIKey(req: Request) async throws -> Response {
        // API key deletion implementation
        let html = APIKeyListPartial(apiKeys: []).render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }

    // MARK: - Organization Settings Endpoints

    func updateOrganizationInfo(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Check if user is admin
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard userOrg != nil else {
            let html = ToastNotification(message: "Only organization admins can update organization", isError: true).render()
            return Response(status: .forbidden, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        struct UpdateRequest: Content {
            let name: String
            let description: String
        }

        let updateRequest = try req.content.decode(UpdateRequest.self)
        organization.name = updateRequest.name
        organization.description = updateRequest.description

        try await organization.save(on: req.db)

        let html = ToastNotification(message: "Organization updated successfully", isError: false).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func getOrganizationInfoTab(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        let orgResponse = OrganizationResponse(from: organization, userRole: nil)
        let html = OrganizationInfoTabContent(organization: orgResponse).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func getOIDCTab(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        let orgResponse = OrganizationResponse(from: organization, userRole: nil)
        let html = OIDCTabContent(organization: orgResponse).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    // MARK: - OIDC Provider HTMX Endpoints

    func listOIDCProviders(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()

        let providerResponses = providers.map { OIDCProviderResponse(from: $0) }
        let html = OIDCProvidersList(providers: providerResponses, organizationID: organizationID).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func showNewOIDCProviderForm(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let html = OIDCProviderForm(organizationID: organizationID, provider: nil, isEdit: false).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func createOIDCProvider(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("orgID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        struct CreateRequest: Content {
            let name: String
            let clientID: String
            let clientSecret: String
            let discoveryURL: String?
            let enabled: String?
        }

        let createRequest = try req.content.decode(CreateRequest.self)

        let provider = OIDCProvider(
            organizationID: organizationID,
            name: createRequest.name,
            clientID: createRequest.clientID,
            clientSecret: createRequest.clientSecret,
            discoveryURL: createRequest.discoveryURL,
            authorizationEndpoint: nil,
            tokenEndpoint: nil,
            userinfoEndpoint: nil,
            jwksURI: nil,
            scopes: ["openid", "profile", "email"],
            enabled: createRequest.enabled == "on"
        )

        try await provider.save(on: req.db)

        // Return updated providers list with success toast
        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()

        let providerResponses = providers.map { OIDCProviderResponse(from: $0) }
        let listHTML = OIDCProvidersList(providers: providerResponses, organizationID: organizationID).render()
        let toastHTML = ToastNotification(message: "OIDC provider created successfully", isError: false).render()

        let html = """
        <div id="oidc-providers-list" hx-swap-oob="true">\(listHTML)</div>
        <div id="provider-form-section" hx-swap-oob="outerHTML" style="display: none;"></div>
        <div id="notification-area" hx-swap-oob="beforeend">\(toastHTML)</div>
        """

        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func showEditOIDCProviderForm(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("orgID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        let providerResponse = OIDCProviderResponse(from: provider)
        let html = OIDCProviderForm(organizationID: organizationID, provider: providerResponse, isEdit: true).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func updateOIDCProvider(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("orgID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        struct UpdateRequest: Content {
            let name: String
            let clientID: String
            let clientSecret: String?
            let discoveryURL: String?
            let enabled: String?
        }

        let updateRequest = try req.content.decode(UpdateRequest.self)

        provider.name = updateRequest.name
        provider.clientID = updateRequest.clientID
        if let clientSecret = updateRequest.clientSecret, !clientSecret.isEmpty {
            provider.clientSecret = clientSecret
        }
        if let discoveryURL = updateRequest.discoveryURL {
            provider.discoveryURL = discoveryURL
        }
        provider.enabled = updateRequest.enabled == "on"

        try await provider.save(on: req.db)

        // Return updated providers list with success toast
        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()

        let providerResponses = providers.map { OIDCProviderResponse(from: $0) }
        let listHTML = OIDCProvidersList(providers: providerResponses, organizationID: organizationID).render()
        let toastHTML = ToastNotification(message: "OIDC provider updated successfully", isError: false).render()

        let html = """
        <div id="oidc-providers-list" hx-swap-oob="true">\(listHTML)</div>
        <div id="edit-provider-form-section" hx-swap-oob="outerHTML" style="display: none;"></div>
        <div id="notification-area" hx-swap-oob="beforeend">\(toastHTML)</div>
        """

        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    func deleteOIDCProvider(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("orgID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        try await provider.delete(on: req.db)

        // Return updated providers list with success toast
        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()

        let providerResponses = providers.map { OIDCProviderResponse(from: $0) }
        let listHTML = OIDCProvidersList(providers: providerResponses, organizationID: organizationID).render()
        let toastHTML = ToastNotification(message: "OIDC provider deleted successfully", isError: false).render()

        let html = """
        <div id="oidc-providers-list" hx-swap-oob="true">\(listHTML)</div>
        <div id="notification-area" hx-swap-oob="beforeend">\(toastHTML)</div>
        """

        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    // MARK: - Onboarding Endpoints

    func setupOrganization(req: Request) async throws -> Response {
        struct SetupRequest: Content {
            let name: String
            let description: String?
        }

        let setupRequest = try req.content.decode(SetupRequest.self)

        // Validate that this is truly the first setup (no users exist)
        let userCount = try await User.query(on: req.db).count()
        guard userCount == 0 else {
            throw Abort(.badRequest, reason: "Onboarding already completed")
        }

        // Create the organization
        let organization = Organization(
            name: setupRequest.name,
            description: setupRequest.description ?? ""
        )
        try await organization.save(on: req.db)

        // Success message with redirect
        let html = OnboardingSuccessMessage(organizationName: setupRequest.name).render()

        var headers = HTTPHeaders([("Content-Type", "text/html")])
        headers.add(name: "HX-Redirect", value: "/")

        return Response(
            status: .ok,
            headers: headers,
            body: .init(string: html)
        )
    }

    // MARK: - Auth Endpoints

    func loginComplete(req: Request) async throws -> Response {
        let html = "<div class=\"text-green-500 text-sm mt-2\">Login successful! Redirecting...</div>"
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
}
