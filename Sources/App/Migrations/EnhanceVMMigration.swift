import Fluent
import Vapor

struct EnhanceVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            // VM status and hypervisor tracking
            .field("status", .string, .required, .sql(.default("'created'")))
            .field("hypervisor_id", .string)
            
            // Enhanced CPU configuration
            .field("max_cpu", .int, .required, .sql(.default("1")))
            
            // Enhanced memory configuration (change memory to int64)
            .field("memory_new", .int64, .required, .sql(.default("536870912"))) // 512MB default
            .field("hugepages", .bool, .required, .sql(.default("false")))
            .field("shared_memory", .bool, .required, .sql(.default("false")))
            
            // Enhanced disk configuration (change disk to int64)
            .field("disk_new", .int64, .required, .sql(.default("1073741824"))) // 1GB default
            .field("disk_path", .string)
            .field("readonly_disk", .bool, .required, .sql(.default("false")))
            
            // Payload configuration
            .field("kernel_path", .string)
            .field("initramfs_path", .string)
            .field("cmdline", .string)
            .field("firmware_path", .string)
            
            // Network configuration
            .field("mac_address", .string)
            .field("ip_address", .string)
            .field("network_mask", .string)
            
            // Console configuration
            .field("console_mode", .string, .required, .sql(.default("'Pty'")))
            .field("serial_mode", .string, .required, .sql(.default("'Pty'")))
            .field("console_socket", .string)
            .field("serial_socket", .string)
            
            // Timestamps
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            
            .update()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("status")
            .deleteField("hypervisor_id")
            .deleteField("max_cpu")
            .deleteField("memory_new")
            .deleteField("hugepages")
            .deleteField("shared_memory")
            .deleteField("disk_new")
            .deleteField("disk_path")
            .deleteField("readonly_disk")
            .deleteField("kernel_path")
            .deleteField("initramfs_path")
            .deleteField("cmdline")
            .deleteField("firmware_path")
            .deleteField("mac_address")
            .deleteField("ip_address")
            .deleteField("network_mask")
            .deleteField("console_mode")
            .deleteField("serial_mode")
            .deleteField("console_socket")
            .deleteField("serial_socket")
            .deleteField("created_at")
            .deleteField("updated_at")
            .update()
    }
}

struct MigrateVMMemoryAndDisk: AsyncMigration {
    func prepare(on database: Database) async throws {
        // For now, just use simple migration without raw SQL
        // The data migration can be done manually if needed
        
        // Drop old fields
        try await database.schema("vms")
            .deleteField("memory")
            .deleteField("disk")
            .update()
        
        // Rename new fields to old names
        try await database.schema("vms")
            .updateField("memory_new", .int64)
            .updateField("disk_new", .int64)
            .update()
    }
    
    func revert(on database: Database) async throws {
        // Add old fields back
        try await database.schema("vms")
            .field("memory", .int, .required, .sql(.default("512")))
            .field("disk", .int, .required, .sql(.default("1")))
            .update()
        
        // Drop new fields
        try await database.schema("vms")
            .deleteField("memory_new")
            .deleteField("disk_new")
            .update()
    }
}