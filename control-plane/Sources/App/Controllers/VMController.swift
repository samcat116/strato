import Foundation
import Vapor
import StratoShared

struct VMController: RouteCollection {
    private static func defaultVMStoragePath() -> String {
        if let override = Environment.get("VM_STORAGE_DIR"), !override.isEmpty {
            return override
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/vms"
        #else
        return "/var/lib/strato/vms"
        #endif
    }

    private static func socketPath(for vmID: UUID, filename: String) -> String {
        let base = defaultVMStoragePath()
        let vmDir = (base as NSString).appendingPathComponent(vmID.uuidString)
        return (vmDir as NSString).appendingPathComponent(filename)
    }

    func boot(routes: any RoutesBuilder) throws {
        let vms = routes.grouped("api", "vms")
        vms.get(use: index)
        vms.post(use: create)
        vms.group(":vmID") { vm in
            vm.get(use: show)
            vm.put(use: update)
            vm.delete(use: delete)
            vm.post("start", use: start)
            vm.post("stop", use: stop)
            vm.post("restart", use: restart)
            vm.post("pause", use: pause)
            vm.post("resume", use: resume)
            vm.get("status", use: status)
        }
    }

    func index(req: Request) async throws -> [VM] {
        // Get user from middleware
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Filter VMs based on user permissions
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

        return authorizedVMs
    }

    func show(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        return vm
    }

    func create(req: Request) async throws -> VM {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        struct CreateVMRequest: Content {
            let name: String
            let description: String?
            let templateName: String?  // Optional - either template or image required
            let imageId: UUID?         // Optional - either template or image required
            let projectId: UUID?
            let environment: String?
            let cpu: Int?
            let memory: Int64?
            let disk: Int64?
            let cmdline: String?
        }

        let createRequest = try req.content.decode(CreateVMRequest.self)

        // Validate that either templateName or imageId is provided (but not both)
        if createRequest.templateName == nil && createRequest.imageId == nil {
            throw Abort(.badRequest, reason: "Either 'templateName' or 'imageId' must be provided")
        }
        if createRequest.templateName != nil && createRequest.imageId != nil {
            throw Abort(.badRequest, reason: "Cannot specify both 'templateName' and 'imageId'")
        }

        // Variables to hold template or image
        var template: VMTemplate?
        var image: Image?

        if let templateName = createRequest.templateName {
            // Find the template
            guard let foundTemplate = try await VMTemplate.query(on: req.db)
                .filter(\VMTemplate.$imageName, .equal, templateName)
                .filter(\VMTemplate.$isActive, .equal, true)
                .first() else {
                throw Abort(.badRequest, reason: "Template '\(templateName)' not found or inactive")
            }
            template = foundTemplate
        } else if let imageId = createRequest.imageId {
            // Find the image
            guard let foundImage = try await Image.find(imageId, on: req.db) else {
                throw Abort(.badRequest, reason: "Image not found")
            }

            // Verify image is ready
            guard foundImage.status == .ready else {
                throw Abort(.badRequest, reason: "Image is not ready. Status: \(foundImage.status.rawValue)")
            }

            // Check user permission on image
            let hasImagePermission = try await req.spicedb.checkPermission(
                subject: user.id?.uuidString ?? "",
                permission: "read",
                resource: "image",
                resourceId: imageId.uuidString
            )

            guard hasImagePermission else {
                throw Abort(.forbidden, reason: "Access denied to image")
            }

            image = foundImage
        }

        // Determine project context
        let projectId: UUID
        if let requestedProjectId = createRequest.projectId {
            // Verify user has access to the requested project
            guard let project = try await Project.find(requestedProjectId, on: req.db) else {
                throw Abort(.badRequest, reason: "Project not found")
            }

            // Verify user belongs to the project's organization
            let rootOrgId = try await project.getRootOrganizationId(on: req.db)
            guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
                throw Abort(.forbidden, reason: "Access denied to project")
            }

            projectId = requestedProjectId
        } else {
            guard let currentOrgId = user.currentOrganizationId else {
                        throw Abort(.badRequest, reason: "No current organization set. Please specify a project.")
            }

            // Find or create default project for organization
            let defaultProject = try await Project.query(on: req.db)
                .filter(\Project.$organization.$id, .equal, currentOrgId)
                .filter(\Project.$name, .equal, "Default Project")
                .first()

            guard let project = defaultProject else {
                throw Abort(.badRequest, reason: "No default project found. Please specify a project.")
            }
            projectId = project.id!
        }

        // Get project to validate environment
        guard let project = try await Project.find(projectId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Project not found")
        }

        // Determine environment
        let environment = createRequest.environment ?? project.defaultEnvironment

        // Validate environment exists in project
        if !project.hasEnvironment(environment) {
            throw Abort(.badRequest, reason: "Environment '\(environment)' not available in project. Available: \(project.environments.joined(separator: ", "))")
        }

        // Create VM instance - either from template or image
        let vm: VM
        if let template = template {
            // Template-based VM creation (legacy)
            vm = try template.createVMInstance(
                name: createRequest.name,
                description: createRequest.description ?? "",
                projectID: projectId,
                environment: environment,
                cpu: createRequest.cpu,
                memory: createRequest.memory,
                disk: createRequest.disk,
                cmdline: createRequest.cmdline
            )
        } else if let image = image {
            // Image-based VM creation (new)
            // Pre-compute values to avoid complex expression
            let cpuValue = createRequest.cpu ?? image.defaultCpu ?? 1
            let memoryValue = createRequest.memory ?? image.defaultMemory ?? Int64(1024 * 1024 * 1024)
            let diskValue = createRequest.disk ?? image.defaultDisk ?? Int64(10 * 1024 * 1024 * 1024)
            let cmdlineValue = createRequest.cmdline ?? image.defaultCmdline

            vm = VM(
                name: createRequest.name,
                description: createRequest.description ?? "",
                image: image.name,
                projectID: projectId,
                environment: environment,
                cpu: cpuValue,
                memory: memoryValue,
                disk: diskValue,
                maxCpu: cpuValue
            )
            vm.cmdline = cmdlineValue
            // Link VM to source image
            vm.$sourceImage.id = image.id
        } else {
            throw Abort(.internalServerError, reason: "Neither template nor image available")
        }

        // Save VM to database first to generate ID
        try await vm.save(on: req.db)

        // Generate unique paths and configurations using the generated ID
        guard let vmID = vm.id else {
            throw Abort(.internalServerError, reason: "VM ID is required after saving")
        }

        if let template = template {
            // Template-based paths
            vm.diskPath = template.generateDiskPath(for: vmID)
            vm.macAddress = template.generateMacAddress()
            vm.kernelPath = template.kernelPath
            vm.initramfsPath = template.initramfsPath
            vm.firmwarePath = template.firmwarePath
            vm.cmdline = vm.cmdline ?? template.defaultCmdline
        } else {
            // Image-based paths - disk will be created by agent from cached image
            vm.diskPath = "/var/lib/strato/vms/\(vmID)/disk.qcow2"
            vm.macAddress = VM.generateMACAddress()
        }

        // Set up console sockets to align with agent VM storage path
        vm.consoleSocket = Self.socketPath(for: vmID, filename: "console.sock")
        vm.serialSocket = Self.socketPath(for: vmID, filename: "serial.sock")

        // Update VM with generated paths
        try await vm.update(on: req.db)

        // Create relationships in SpiceDB
        let vmId = vm.id?.uuidString ?? ""
        let userId = user.id?.uuidString ?? ""

        // Create ownership relationship
        try await req.spicedb.writeRelationship(
            entity: "virtual_machine",
            entityId: vmId,
            relation: "owner",
            subject: "user",
            subjectId: userId
        )

        // Link VM to project
        try await req.spicedb.writeRelationship(
            entity: "virtual_machine",
            entityId: vmId,
            relation: "project",
            subject: "project",
            subjectId: projectId.uuidString
        )

        if let currentOrgId = user.currentOrganizationId {
            try await req.spicedb.writeRelationship(
                entity: "virtual_machine",
                entityId: vmId,
                relation: "organization",
                subject: "organization",
                subjectId: currentOrgId.uuidString
        )
        }

        // Create VM via agent (scheduler will select best hypervisor and set hypervisorId)
        do {
            let vmConfig: VmConfig

            if let template = template {
                // Template-based creation
                vmConfig = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)
            } else if let image = image {
                // Image-based creation
                vmConfig = try await VMConfigBuilder.buildVMConfig(from: vm, image: image)
            } else {
                throw Abort(.internalServerError, reason: "Neither template nor image available")
            }

            // Pass the Image object to AgentService - it will build ImageInfo with signed URL
            // after the scheduler selects the target agent
            try await req.agentService.createVM(vm: vm, vmConfig: vmConfig, db: req.db, image: image)

            // hypervisorId is set and saved by AgentService via scheduler
            req.logger.info("VM created successfully via agent", metadata: [
                "vm_id": .string(vmID.uuidString),
                "hypervisor_id": .string(vm.hypervisorId ?? "unknown"),
                "created_from": .string(template != nil ? "template" : "image")
            ])
        } catch {
            req.logger.error("Failed to create VM via agent: \(error)", metadata: ["vm_id": .string(vmID.uuidString)])

            // Don't fail the entire request - VM is created in DB but not in hypervisor
            // This allows for manual retry later
        }

        return vm
    }

    func update(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let existingVM = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        struct UpdateVMRequest: Content {
            let name: String?
            let description: String?
        }

        let updateRequest = try req.content.decode(UpdateVMRequest.self)

        // Only allow updating name and description for now
        // Resource changes would require VM shutdown and recreation
        if let name = updateRequest.name {
            existingVM.name = name
        }

        if let description = updateRequest.description {
            existingVM.description = description
        }

        try await existingVM.save(on: req.db)
        return existingVM
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Stop and delete VM via agent first
        if vm.hypervisorId != nil {
            do {
                try await req.agentService.performVMOperation(.vmShutdown, vmId: vm.id?.uuidString ?? "")
                try await req.agentService.performVMOperation(.vmDelete, vmId: vm.id?.uuidString ?? "")
                req.logger.info("VM deleted via agent", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])
            } catch {
                req.logger.warning("Failed to delete VM via agent: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])
                // Continue with database deletion even if agent deletion fails
            }
        }

        // Delete from database
        try await vm.delete(on: req.db)
        return .ok
    }

    func pause(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard vm.canPause else {
            throw Abort(.badRequest, reason: "VM cannot be paused in current state: \(vm.status.rawValue)")
        }

        do {
            try await req.agentService.performVMOperation(.vmPause, vmId: vm.id?.uuidString ?? "")

            vm.status = VMStatus.paused
            try await vm.save(on: req.db)

            req.logger.info("VM paused successfully", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

        } catch {
            req.logger.error("Failed to pause VM: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

            let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
            vm.status = actualStatus
            try await vm.save(on: req.db)

            throw Abort(.internalServerError, reason: "Failed to pause VM: \(error.localizedDescription)")
        }

        return vm
    }

    func resume(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard vm.canResume else {
            throw Abort(.badRequest, reason: "VM cannot be resumed in current state: \(vm.status.rawValue)")
        }

        do {
            try await req.agentService.performVMOperation(.vmResume, vmId: vm.id?.uuidString ?? "")

            vm.status = VMStatus.running
            try await vm.save(on: req.db)

            req.logger.info("VM resumed successfully", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

        } catch {
            req.logger.error("Failed to resume VM: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

            let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
            vm.status = actualStatus
            try await vm.save(on: req.db)

            throw Abort(.internalServerError, reason: "Failed to resume VM: \(error.localizedDescription)")
        }

        return vm
    }

    func status(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Sync status with agent if VM exists there
        if vm.hypervisorId != nil {
            do {
                let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
                if actualStatus != vm.status {
                    vm.status = actualStatus
                    try await vm.save(on: req.db)
                }
            } catch {
                req.logger.warning("Failed to sync VM status with agent: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])
            }
        }

        return vm
    }

    func start(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard vm.canStart else {
            throw Abort(.badRequest, reason: "VM cannot be started in current state: \(vm.status.rawValue)")
        }

        do {
            if vm.status == .created || vm.status == .shutdown {
                // Boot the VM (fresh start or restart after shutdown)
                try await req.agentService.performVMOperation(.vmBoot, vmId: vm.id?.uuidString ?? "")
            } else {
                // Resume from paused state
                try await req.agentService.performVMOperation(.vmResume, vmId: vm.id?.uuidString ?? "")
            }

            // Update VM status
            vm.status = VMStatus.running
            try await vm.save(on: req.db)

            req.logger.info("VM started successfully", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

        } catch {
            req.logger.error("Failed to start VM: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

            // Sync status with agent
            let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
            vm.status = actualStatus
            try await vm.save(on: req.db)

            throw Abort(.internalServerError, reason: "Failed to start VM: \(error.localizedDescription)")
        }

        return vm
    }

    func stop(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard vm.canStop else {
            throw Abort(.badRequest, reason: "VM cannot be stopped in current state: \(vm.status.rawValue)")
        }

        do {
            try await req.agentService.performVMOperation(.vmShutdown, vmId: vm.id?.uuidString ?? "")

            // Update VM status
            vm.status = VMStatus.shutdown
            try await vm.save(on: req.db)

            req.logger.info("VM stopped successfully", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

        } catch {
            req.logger.error("Failed to stop VM: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

            // Sync status with agent
            let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
            vm.status = actualStatus
            try await vm.save(on: req.db)

            throw Abort(.internalServerError, reason: "Failed to stop VM: \(error.localizedDescription)")
        }

        return vm
    }

    func restart(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard vm.isRunning else {
            throw Abort(.badRequest, reason: "VM must be running to restart. Current state: \(vm.status.rawValue)")
        }

        do {
            try await req.agentService.performVMOperation(.vmReboot, vmId: vm.id?.uuidString ?? "")

            req.logger.info("VM restarted successfully", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

        } catch {
            req.logger.error("Failed to restart VM: \(error)", metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])

            // Sync status with agent
            let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
            vm.status = actualStatus
            try await vm.save(on: req.db)

            throw Abort(.internalServerError, reason: "Failed to restart VM: \(error.localizedDescription)")
        }

        return vm
    }
}
