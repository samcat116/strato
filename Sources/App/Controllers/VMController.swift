import Foundation
import Vapor

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
            let hasPermission = try await req.permify.checkPermission(
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
        
        let vm = try req.content.decode(VM.self)
        try await vm.save(on: req.db)
        
        // Create ownership relationship in Permify
        try await req.permify.writeRelationship(
            entity: "vm",
            entityId: vm.id?.uuidString ?? "",
            relation: "owner",
            subject: "user",
            subjectId: user.id?.uuidString ?? ""
        )
        
        return vm
    }
    
    func update(req: Request) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }
        
        guard let existingVM = try await VM.find(vmID, on: req.db) else {
            throw Abort(.notFound)
        }
        
        let updatedVM = try req.content.decode(VM.self)
        existingVM.name = updatedVM.name
        existingVM.description = updatedVM.description
        existingVM.image = updatedVM.image
        existingVM.cpu = updatedVM.cpu
        existingVM.memory = updatedVM.memory
        existingVM.disk = updatedVM.disk
        
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
        
        try await vm.delete(on: req.db)
        return .ok
    }
    
    func start(req: Request) async throws -> HTTPStatus {
        // TODO: Implement VM start logic with Cloud Hypervisor API
        return .ok
    }
    
    func stop(req: Request) async throws -> HTTPStatus {
        // TODO: Implement VM stop logic with Cloud Hypervisor API
        return .ok
    }
    
    func restart(req: Request) async throws -> HTTPStatus {
        // TODO: Implement VM restart logic with Cloud Hypervisor API
        return .ok
    }
}
