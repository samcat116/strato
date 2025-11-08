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

// MARK: - Partial Templates

struct VMListPartial: HTML {
    let vms: [VM]

    var content: some HTML {
        if vms.isEmpty {
            tr {
                td(.class("px-3 py-4 text-sm text-gray-400 text-center"), .custom(name: "colspan", value: "3")) {
                    "No VMs found. Create your first VM!"
                }
            }
        } else {
            ForEach(vms) { vm in
                tr(
                    .class("hover:bg-gray-700 cursor-pointer transition-colors"),
                    .custom(name: "hx-get", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/details"),
                    .custom(name: "hx-target", value: "#vmDetails"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    td(.class("px-3 py-3")) {
                        div(.class("text-sm font-medium text-gray-200")) { vm.name }
                        div(.class("text-xs text-gray-400")) { vm.description }
                    }
                    td(.class("px-3 py-3")) {
                        span(.class("inline-flex px-2 py-1 text-xs rounded-full bg-green-900 text-green-300 border border-green-700")) {
                            "Running"
                        }
                    }
                    td(.class("px-3 py-3")) {
                        div(.class("flex space-x-1")) {
                            button(
                                .class("text-green-400 hover:text-green-300 text-xs transition-colors"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/start"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM start command sent')")
                            ) { "▶" }
                            button(
                                .class("text-yellow-400 hover:text-yellow-300 text-xs transition-colors"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/stop"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM stop command sent')")
                            ) { "⏸" }
                            button(
                                .class("text-red-400 hover:text-red-300 text-xs transition-colors"),
                                .custom(name: "hx-delete", value: "/htmx/vms/\(vm.id?.uuidString ?? "")"),
                                .custom(name: "hx-target", value: "#vmTableBody"),
                                .custom(name: "hx-swap", value: "innerHTML"),
                                .custom(name: "hx-confirm", value: "Are you sure you want to delete this VM?"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM deleted')")
                            ) { "🗑" }
                        }
                    }
                }
            }
        }
    }
}

struct VMDetailsPartial: HTML {
    let vm: VM

    var content: some HTML {
        div(.class("space-y-4")) {
            div {
                h4(.class("text-lg font-semibold text-gray-100")) { vm.name }
                p(.class("text-sm text-gray-300")) { vm.description }
            }
            div(.class("grid grid-cols-2 gap-4")) {
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "CPU Cores" }
                    p(.class("text-sm text-gray-100")) { String(vm.cpu) }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Memory" }
                    p(.class("text-sm text-gray-100")) { "\(String(format: "%.1f", Double(vm.memory) / (1024 * 1024 * 1024))) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Disk" }
                    p(.class("text-sm text-gray-100")) { "\(vm.disk / (1024 * 1024 * 1024)) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-400")) { "Image" }
                    p(.class("text-sm text-gray-100")) { vm.image }
                }
            }
            div(.class("flex space-x-3 pt-4")) {
                button(
                    .class("bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/start")
                ) { "Start" }
                button(
                    .class("bg-yellow-600 hover:bg-yellow-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/stop")
                ) { "Stop" }
                button(
                    .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/restart")
                ) { "Restart" }
                button(
                    .class("bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-md text-sm transition-colors"),
                    .custom(name: "hx-delete", value: "/htmx/vms/\(vm.id?.uuidString ?? "")"),
                    .custom(name: "hx-target", value: "#vmTableBody"),
                    .custom(name: "hx-swap", value: "innerHTML"),
                    .custom(name: "hx-confirm", value: "Are you sure you want to delete this VM?")
                ) { "Delete" }
            }
        }
    }
}

struct VMActionResponsePartial: HTML {
    let message: String

    var content: some HTML {
        div { message }
    }
}

struct OrganizationListPartial: HTML {
    let organizations: [OrganizationResponse]
    let currentOrgId: UUID?

    var content: some HTML {
        if organizations.isEmpty {
            div(.class("px-4 py-2 text-sm text-gray-400")) { "No organizations found" }
        } else {
            ForEach(organizations) { org in
                let isCurrent = org.id == currentOrgId
                let buttonClass = "w-full text-left px-4 py-2 text-sm hover:bg-gray-700 flex justify-between items-center transition-colors" + (isCurrent ? " bg-gray-700" : "")
                button(
                    .class(buttonClass),
                    .custom(name: "hx-post", value: "/htmx/organizations/\(org.id?.uuidString ?? "")/switch"),
                    .custom(name: "hx-target", value: "#orgList"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    div {
                        div(.class("font-medium \(isCurrent ? "text-blue-400" : "text-gray-300")")) {
                            if isCurrent { "✓ \(org.name)" } else { org.name }
                        }
                        div(.class("text-xs text-gray-400")) { org.description }
                    }
                    span(.class("text-xs text-gray-500")) { org.userRole ?? "member" }
                }
            }
        }
    }
}

struct APIKeyListPartial: HTML {
    let apiKeys: [APIKey]

    var content: some HTML {
        if apiKeys.isEmpty {
            div(.class("text-center text-gray-400 py-8")) {
                "No API keys found. Create your first API key!"
            }
        } else {
            div(.class("space-y-4")) {
                ForEach(apiKeys) { key in
                    div(.class("border border-gray-600 bg-gray-700 rounded-lg p-4")) {
                        div(.class("flex justify-between items-start")) {
                            div(.class("flex-1")) {
                                h4(.class("font-medium text-gray-100")) { key.name }
                                p(.class("text-sm text-gray-400 font-mono")) { key.keyPrefix }
                            }
                            div(.class("flex space-x-2")) {
                                button(
                                    .class("text-sm px-3 py-1 rounded bg-red-900 text-red-300 hover:bg-red-800 transition-colors border border-red-700"),
                                    .custom(name: "hx-delete", value: "/htmx/api-keys/\(key.id?.uuidString ?? "")"),
                                    .custom(name: "hx-target", value: "#apiKeysList"),
                                    .custom(name: "hx-swap", value: "innerHTML")
                                ) { "Delete" }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Organization Settings Components

struct ToastNotification: HTML {
    let message: String
    let isError: Bool

    var content: some HTML {
        div(
            .class("fixed top-4 right-4 px-6 py-3 rounded-lg shadow-lg z-50 animate-fade-in"),
            .class(isError ? "bg-red-500 text-white" : "bg-green-500 text-white"),
            .custom(name: "x-data", value: "{ show: true }"),
            .custom(name: "x-init", value: "setTimeout(() => $el.remove(), 3000)")
        ) {
            message
        }
    }
}

struct OrganizationInfoTabContent: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        div(.class("bg-white shadow rounded-lg")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "Organization Information"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Update your organization's basic information and settings."
                }
            }

            div(.class("px-6 py-6")) {
                form(
                    .id("organization-info-form"),
                    .custom(name: "hx-put", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/update"),
                    .custom(name: "hx-target", value: "#notification-area"),
                    .custom(name: "hx-swap", value: "beforeend")
                ) {
                    div(.class("grid grid-cols-1 gap-6")) {
                        div {
                            label(.for("name"), .class("block text-sm font-medium text-gray-700")) {
                                "Organization Name"
                            }
                            input(
                                .type(.text),
                                .name("name"),
                                .id("name"),
                                .value(organization.name),
                                .required,
                                .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                                .placeholder("Enter organization name")
                            )
                        }

                        div {
                            label(.for("description"), .class("block text-sm font-medium text-gray-700")) {
                                "Description"
                            }
                            textarea(
                                .name("description"),
                                .id("description"),
                                .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm h-20"),
                                .placeholder("Enter a description for your organization")
                            ) { organization.description }
                        }
                    }

                    div(.class("mt-6 flex justify-end")) {
                        button(
                            .type(.submit),
                            .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                        ) {
                            "Save Changes"
                        }
                    }
                }
            }
        }
    }
}

struct OIDCTabContent: HTML {
    let organization: OrganizationResponse

    var content: some HTML {
        div(.class("bg-white shadow rounded-lg")) {
            div(.class("px-6 py-4 border-b border-gray-200")) {
                h2(.class("text-lg font-medium text-gray-900")) {
                    "OIDC Authentication Providers"
                }
                p(.class("mt-1 text-sm text-gray-600")) {
                    "Configure OpenID Connect providers for single sign-on authentication."
                }
            }

            div(.class("px-6 py-6")) {
                div(
                    .id("oidc-providers-list"),
                    .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/oidc-providers/list"),
                    .custom(name: "hx-trigger", value: "load"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    p(.class("text-gray-500")) { "Loading OIDC providers..." }
                }

                div(.class("mt-6"), .id("add-provider-button")) {
                    button(
                        .type(.button),
                        .class("inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"),
                        .custom(name: "hx-get", value: "/htmx/organizations/\(organization.id?.uuidString ?? "")/settings/oidc-providers/form/new"),
                        .custom(name: "hx-target", value: "#provider-form-section"),
                        .custom(name: "hx-swap", value: "innerHTML")
                    ) {
                        "➕ Add OIDC Provider"
                    }
                }

                div(.class("mt-6"), .id("provider-form-section"), .style("display: none;")) {}
                div(.class("mt-6"), .id("edit-provider-form-section"), .style("display: none;")) {}
            }
        }
    }
}

struct OIDCProvidersList: HTML {
    let providers: [OIDCProviderResponse]
    let organizationID: UUID

    var content: some HTML {
        if providers.isEmpty {
            p(.class("text-gray-500 text-center py-4")) { "No OIDC providers configured" }
        } else {
            ForEach(providers) { provider in
                div(.class("border rounded-lg p-4 mb-4")) {
                    div(.class("flex justify-between items-center")) {
                        div(.class("flex-1")) {
                            h4(.class("font-medium text-gray-900")) { provider.name }
                            p(.class("text-sm text-gray-500")) { "Client ID: \(provider.clientID)" }
                            p(.class("text-sm text-gray-500")) { "Status: \(provider.enabled ? "Enabled" : "Disabled")" }
                        }
                        div(.class("space-x-2 flex-shrink-0")) {
                            button(
                                .class("text-indigo-600 hover:text-indigo-900"),
                                .custom(name: "hx-get", value: "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider.id?.uuidString ?? "")/form/edit"),
                                .custom(name: "hx-target", value: "#edit-provider-form-section"),
                                .custom(name: "hx-swap", value: "innerHTML")
                            ) { "Edit" }
                            button(
                                .class("text-red-600 hover:text-red-900"),
                                .custom(name: "hx-delete", value: "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider.id?.uuidString ?? "")"),
                                .custom(name: "hx-confirm", value: "Are you sure you want to delete this OIDC provider?")
                            ) { "Delete" }
                        }
                    }
                }
            }
        }
    }
}

struct OIDCProviderForm: HTML {
    let organizationID: UUID
    let provider: OIDCProviderResponse?
    let isEdit: Bool

    var content: some HTML {
        form(
            .id(isEdit ? "edit-oidc-provider-form" : "oidc-provider-form"),
            .custom(name: isEdit ? "hx-put" : "hx-post", value: isEdit ? "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/\(provider?.id?.uuidString ?? "")/update" : "/htmx/organizations/\(organizationID.uuidString)/settings/oidc-providers/create")
        ) {
            div(.class("grid grid-cols-1 gap-6")) {
                div {
                    label(.for("name"), .class("block text-sm font-medium text-gray-700")) {
                        "Provider Name"
                    }
                    input(
                        .type(.text),
                        .name("name"),
                        .id("name"),
                        .value(provider?.name ?? ""),
                        .required,
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("e.g., Azure AD, Google Workspace, Okta")
                    )
                }

                div {
                    label(.for("clientID"), .class("block text-sm font-medium text-gray-700")) {
                        "Client ID"
                    }
                    input(
                        .type(.text),
                        .name("clientID"),
                        .id("clientID"),
                        .value(provider?.clientID ?? ""),
                        .required,
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("Client ID from your OIDC provider")
                    )
                }

                div {
                    label(.for("clientSecret"), .class("block text-sm font-medium text-gray-700")) {
                        isEdit ? "Client Secret (leave blank to keep current)" : "Client Secret"
                    }
                    input(
                        .type(.password),
                        .name("clientSecret"),
                        .id("clientSecret"),
                        .required(!isEdit),
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder(isEdit ? "Leave blank to keep existing secret" : "Client Secret from your OIDC provider")
                    )
                }

                div {
                    label(.for("discoveryURL"), .class("block text-sm font-medium text-gray-700")) {
                        "Discovery URL"
                    }
                    input(
                        .type(.url),
                        .name("discoveryURL"),
                        .id("discoveryURL"),
                        .value(provider?.discoveryURL ?? ""),
                        .class("mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"),
                        .placeholder("https://provider.com/.well-known/openid-configuration")
                    )
                }

                div {
                    div(.class("flex items-center")) {
                        input(
                            .type(.checkbox),
                            .name("enabled"),
                            .id("enabled"),
                            .checked(provider?.enabled ?? true),
                            .class("h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded")
                        )
                        label(.for("enabled"), .class("ml-2 block text-sm text-gray-900")) {
                            "Enable this provider"
                        }
                    }
                }
            }

            div(.class("mt-6 flex justify-end space-x-3")) {
                button(
                    .type(.button),
                    .class("inline-flex justify-center rounded-md border border-gray-300 bg-white py-2 px-4 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2"),
                    .custom(name: "onclick", value: "document.getElementById('\(isEdit ? "edit-provider-form-section" : "provider-form-section")').style.display='none'")
                ) {
                    "Cancel"
                }
                button(
                    .type(.submit),
                    .class("inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2")
                ) {
                    isEdit ? "Update Provider" : "Save Provider"
                }
            }
        }
    }
}

// MARK: - Onboarding Components

struct OnboardingSuccessMessage: HTML {
    let organizationName: String

    var content: some HTML {
        div(.class("text-center")) {
            div(.class("bg-green-100 border border-green-400 text-green-700 px-4 py-3 rounded mb-4")) {
                strong { "Success!" }
                " Your organization \"\(organizationName)\" has been created."
            }
            p(.class("text-gray-600 mb-4")) { "Redirecting to your dashboard..." }
            div(.class("animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600 mx-auto")) {}
        }
    }
}
