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

        // API Key endpoints
        let apiKeys = htmx.grouped("api-keys")
        apiKeys.get("list", use: listAPIKeys)
        apiKeys.post("create", use: createAPIKey)
        apiKeys.patch(":keyID", "toggle", use: toggleAPIKey)
        apiKeys.delete(":keyID", use: deleteAPIKey)

        // Auth completion endpoints
        let auth = htmx.grouped("auth")
        auth.post("login", "complete", use: loginComplete)
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

        // Create VM (simplified - you'll need to adapt this to your VM creation logic)
        let vm = VM()
        vm.name = createRequest.vmName
        vm.description = createRequest.vmDescription
        vm.cpu = cpu
        vm.memory = memory
        vm.disk = disk
        vm.image = createRequest.vmTemplate

        // You'll need to add project assignment logic here

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
                td(.class("px-3 py-4 text-sm text-gray-500 text-center"), .custom(name: "colspan", value: "3")) {
                    "No VMs found. Create your first VM!"
                }
            }
        } else {
            ForEach(vms) { vm in
                tr(
                    .class("hover:bg-gray-50 cursor-pointer"),
                    .custom(name: "hx-get", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/details"),
                    .custom(name: "hx-target", value: "#vmDetails"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    td(.class("px-3 py-3")) {
                        div(.class("text-sm font-medium text-gray-900")) { vm.name }
                        div(.class("text-xs text-gray-500")) { vm.description }
                    }
                    td(.class("px-3 py-3")) {
                        span(.class("inline-flex px-2 py-1 text-xs rounded-full bg-green-100 text-green-800")) {
                            "Running"
                        }
                    }
                    td(.class("px-3 py-3")) {
                        div(.class("flex space-x-1")) {
                            button(
                                .class("text-green-600 hover:text-green-700 text-xs"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/start"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM start command sent')")
                            ) { "▶" }
                            button(
                                .class("text-yellow-600 hover:text-yellow-700 text-xs"),
                                .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/stop"),
                                .custom(name: "hx-target", value: "#terminal"),
                                .custom(name: "hx-on::after-request", value: "logToConsole('VM stop command sent')")
                            ) { "⏸" }
                            button(
                                .class("text-red-600 hover:text-red-700 text-xs"),
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
                h4(.class("text-lg font-semibold text-gray-900")) { vm.name }
                p(.class("text-sm text-gray-600")) { vm.description }
            }
            div(.class("grid grid-cols-2 gap-4")) {
                div {
                    label(.class("block text-sm font-medium text-gray-700")) { "CPU Cores" }
                    p(.class("text-sm text-gray-900")) { String(vm.cpu) }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-700")) { "Memory" }
                    p(.class("text-sm text-gray-900")) { "\(String(format: "%.1f", Double(vm.memory) / (1024 * 1024 * 1024))) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-700")) { "Disk" }
                    p(.class("text-sm text-gray-900")) { "\(vm.disk / (1024 * 1024 * 1024)) GB" }
                }
                div {
                    label(.class("block text-sm font-medium text-gray-700")) { "Image" }
                    p(.class("text-sm text-gray-900")) { vm.image }
                }
            }
            div(.class("flex space-x-3 pt-4")) {
                button(
                    .class("bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-md text-sm"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/start")
                ) { "Start" }
                button(
                    .class("bg-yellow-600 hover:bg-yellow-700 text-white px-4 py-2 rounded-md text-sm"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/stop")
                ) { "Stop" }
                button(
                    .class("bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md text-sm"),
                    .custom(name: "hx-post", value: "/htmx/vms/\(vm.id?.uuidString ?? "")/restart")
                ) { "Restart" }
                button(
                    .class("bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-md text-sm"),
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
            div(.class("px-4 py-2 text-sm text-gray-500")) { "No organizations found" }
        } else {
            ForEach(organizations) { org in
                let isCurrent = org.id == currentOrgId
                let buttonClass = "w-full text-left px-4 py-2 text-sm hover:bg-gray-50 flex justify-between items-center" + (isCurrent ? " bg-indigo-50" : "")
                button(
                    .class(buttonClass),
                    .custom(name: "hx-post", value: "/htmx/organizations/\(org.id?.uuidString ?? "")/switch"),
                    .custom(name: "hx-target", value: "#orgList"),
                    .custom(name: "hx-swap", value: "innerHTML")
                ) {
                    div {
                        div(.class("font-medium \(isCurrent ? "text-indigo-600" : "")")) {
                            if isCurrent { "✓ \(org.name)" } else { org.name }
                        }
                        div(.class("text-xs text-gray-500")) { org.description }
                    }
                    span(.class("text-xs text-gray-400")) { org.userRole ?? "member" }
                }
            }
        }
    }
}

struct APIKeyListPartial: HTML {
    let apiKeys: [APIKey]

    var content: some HTML {
        if apiKeys.isEmpty {
            div(.class("text-center text-gray-500 py-8")) {
                "No API keys found. Create your first API key!"
            }
        } else {
            div(.class("space-y-4")) {
                ForEach(apiKeys) { key in
                    div(.class("border border-gray-200 rounded-lg p-4")) {
                        div(.class("flex justify-between items-start")) {
                            div(.class("flex-1")) {
                                h4(.class("font-medium text-gray-900")) { key.name }
                                p(.class("text-sm text-gray-500 font-mono")) { key.keyPrefix }
                            }
                            div(.class("flex space-x-2")) {
                                button(
                                    .class("text-sm px-3 py-1 rounded bg-red-100 text-red-700 hover:bg-red-200"),
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
