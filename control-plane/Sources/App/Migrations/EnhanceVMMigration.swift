import Fluent
import Vapor
import SQLKit
import FluentSQLiteDriver

struct EnhanceVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // For SQLite compatibility, add fields one at a time

        // VM status and hypervisor tracking
        try await database.schema("vms")
            .field("status", .string, .required, .sql(.default("Created")))
            .update()

        try await database.schema("vms")
            .field("hypervisor_id", .string)
            .update()

        // Enhanced CPU configuration
        try await database.schema("vms")
            .field("max_cpu", .int, .required, .sql(.default("1")))
            .update()

        // Enhanced memory configuration (change memory to int64)
        try await database.schema("vms")
            .field("memory_new", .int64, .required, .sql(.default("536870912")))  // 512MB default
            .update()

        try await database.schema("vms")
            .field("hugepages", .bool, .required, .sql(.default("false")))
            .update()

        try await database.schema("vms")
            .field("shared_memory", .bool, .required, .sql(.default("false")))
            .update()

        // Enhanced disk configuration (change disk to int64)
        try await database.schema("vms")
            .field("disk_new", .int64, .required, .sql(.default("1073741824")))  // 1GB default
            .update()

        try await database.schema("vms")
            .field("disk_path", .string)
            .update()

        try await database.schema("vms")
            .field("readonly_disk", .bool, .required, .sql(.default("false")))
            .update()

        // Payload configuration
        try await database.schema("vms")
            .field("kernel_path", .string)
            .update()

        try await database.schema("vms")
            .field("initramfs_path", .string)
            .update()

        try await database.schema("vms")
            .field("cmdline", .string)
            .update()

        try await database.schema("vms")
            .field("firmware_path", .string)
            .update()

        // Network configuration
        try await database.schema("vms")
            .field("mac_address", .string)
            .update()

        try await database.schema("vms")
            .field("ip_address", .string)
            .update()

        try await database.schema("vms")
            .field("network_mask", .string)
            .update()

        // Console configuration
        try await database.schema("vms")
            .field("console_mode", .string, .required, .sql(.default("Pty")))
            .update()

        try await database.schema("vms")
            .field("serial_mode", .string, .required, .sql(.default("Pty")))
            .update()

        try await database.schema("vms")
            .field("console_socket", .string)
            .update()

        try await database.schema("vms")
            .field("serial_socket", .string)
            .update()

        // Timestamps
        try await database.schema("vms")
            .field("created_at", .datetime)
            .update()

        try await database.schema("vms")
            .field("updated_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        // Delete fields one at a time for SQLite compatibility
        let fieldsToDelete = [
            "status", "hypervisor_id", "max_cpu", "memory_new", "hugepages", "shared_memory",
            "disk_new", "disk_path", "readonly_disk", "kernel_path", "initramfs_path",
            "cmdline", "firmware_path", "mac_address", "ip_address", "network_mask",
            "console_mode", "serial_mode", "console_socket", "serial_socket",
            "created_at", "updated_at",
        ]

        for field in fieldsToDelete {
            try await database.schema("vms")
                .deleteField(.string(field))
                .update()
        }
    }
}
