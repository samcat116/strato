import Foundation
import Vapor
import StratoShared

struct VMController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let vms = routes.grouped("vms")
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
                resource: "vm",
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
            let description: String
            let templateName: String
            let cpu: Int?
            let memory: Int64?
            let disk: Int64?
            let cmdline: String?
        }
        
        let createRequest = try req.content.decode(CreateVMRequest.self)
        
        // Find the template
        guard let template = try await VMTemplate.query(on: req.db)
            .filter(\VMTemplate.$imageName, .equal, createRequest.templateName)
            .filter(\VMTemplate.$isActive, .equal, true)
            .first() else {
            throw Abort(.badRequest, reason: "Template '\(createRequest.templateName)' not found or inactive")
        }
        
        // Create VM instance from template
        let vm = try template.createVMInstance(
            name: createRequest.name,
            description: createRequest.description,
            cpu: createRequest.cpu,
            memory: createRequest.memory,
            disk: createRequest.disk,
            cmdline: createRequest.cmdline
        )
        
        // Save VM to database first to generate ID
        try await vm.save(on: req.db)
        
        // Generate unique paths and configurations using the generated ID
        vm.diskPath = template.generateDiskPath(for: vm.id!)
        vm.macAddress = template.generateMacAddress()
        vm.kernelPath = template.kernelPath
        vm.initramfsPath = template.initramfsPath
        vm.firmwarePath = template.firmwarePath
        vm.cmdline = vm.cmdline ?? template.defaultCmdline
        
        // Set up console sockets
        vm.consoleSocket = "/tmp/vm-\(vm.id!.uuidString)-console.sock"
        vm.serialSocket = "/tmp/vm-\(vm.id!.uuidString)-serial.sock"
        
        // Update VM with generated paths
        try await vm.update(on: req.db)
        
        // Create relationships in SpiceDB
        let vmId = vm.id?.uuidString ?? ""
        let userId = user.id?.uuidString ?? ""
        
        // Create ownership relationship
        try await req.spicedb.writeRelationship(
            entity: "vm",
            entityId: vmId,
            relation: "owner",
            subject: "user",
            subjectId: userId
        )
        
        // Link VM to user's current organization
        if let currentOrgId = user.currentOrganizationId {
            try await req.spicedb.writeRelationship(
                entity: "vm",
                entityId: vmId,
                relation: "organization",
                subject: "organization",
                subjectId: currentOrgId.uuidString
            )
        }
        
        // Create VM via agent
        do {
            let vmConfig = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)
            try await req.agentService.createVM(vm: vm, vmConfig: vmConfig)
            
            // Update VM status
            vm.status = VMStatus.created
            vm.hypervisorId = vm.id?.uuidString
            try await vm.save(on: req.db)
            
            req.logger.info("VM created successfully via agent", metadata: ["vm_id": .string(vmId)])
        } catch {
            req.logger.error("Failed to create VM via agent: \(error)", metadata: ["vm_id": .string(vmId)])
            
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
    
    func pause(req: Request) async throws -> HTTPStatus {
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
        
        return .ok
    }
    
    func resume(req: Request) async throws -> HTTPStatus {
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
        
        return .ok
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
    
    func start(req: Request) async throws -> HTTPStatus {
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
            if vm.status == .created {
                // Boot the VM
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
        
        return .ok
    }
    
    func stop(req: Request) async throws -> HTTPStatus {
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
        
        return .ok
    }
    
    func restart(req: Request) async throws -> HTTPStatus {
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
        
        return .ok
    }
}
