import Fluent
import Vapor

struct CreateVMTemplate: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vm_templates")
            .id()

            // Template identification
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("image_name", .string, .required)

            // Default resource specifications
            .field("default_cpu", .int, .required)
            .field("default_memory", .int64, .required)
            .field("default_disk", .int64, .required)

            // Payload paths for this template
            .field("kernel_path", .string, .required)
            .field("initramfs_path", .string)
            .field("base_disk_path", .string, .required)
            .field("firmware_path", .string)
            .field("default_cmdline", .string, .required)

            // Default network configuration
            .field("default_mac_prefix", .string)
            .field("default_ip_range", .string)

            // Template settings
            .field("is_active", .bool, .required, .sql(.default("true")))
            .field("supports_hugepages", .bool, .required, .sql(.default("false")))
            .field("supports_shared_memory", .bool, .required, .sql(.default("false")))

            // Minimum requirements
            .field("min_cpu", .int, .required, .sql(.default("1")))
            .field("min_memory", .int64, .required, .sql(.default("536870912"))) // 512MB
            .field("min_disk", .int64, .required, .sql(.default("1073741824"))) // 1GB

            // Maximum limits
            .field("max_cpu", .int, .required, .sql(.default("32")))
            .field("max_memory", .int64, .required, .sql(.default("34359738368"))) // 32GB
            .field("max_disk", .int64, .required, .sql(.default("1099511627776"))) // 1TB

            // Timestamps
            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            // Unique constraint on image_name
            .unique(on: "image_name")

            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vm_templates").delete()
    }
}

struct SeedVMTemplates: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Create some default VM templates
        let ubuntuTemplate = VMTemplate(
            name: "Ubuntu 22.04 LTS",
            description: "Ubuntu 22.04 LTS Server with Cloud-Init support",
            imageName: "ubuntu-22.04",
            defaultCpu: 2,
            defaultMemory: 2 * 1024 * 1024 * 1024, // 2GB
            defaultDisk: 20 * 1024 * 1024 * 1024, // 20GB
            kernelPath: "/images/ubuntu-22.04/vmlinuz",
            baseDiskPath: "/images/ubuntu-22.04/disk.qcow2",
            defaultCmdline: "console=ttyS0 root=/dev/vda1 rw",
            initramfsPath: "/images/ubuntu-22.04/initrd.img",
            supportsHugepages: true,
            supportsSharedMemory: true,
            minMemory: 1024 * 1024 * 1024, // 1GB
            minDisk: 10 * 1024 * 1024 * 1024 // 10GB
        )

        let alpineTemplate = VMTemplate(
            name: "Alpine Linux",
            description: "Lightweight Alpine Linux for containers and microservices",
            imageName: "alpine-3.18",
            defaultCpu: 1,
            defaultMemory: 512 * 1024 * 1024, // 512MB
            defaultDisk: 2 * 1024 * 1024 * 1024, // 2GB
            kernelPath: "/images/alpine-3.18/vmlinuz",
            baseDiskPath: "/images/alpine-3.18/disk.qcow2",
            defaultCmdline: "console=ttyS0 root=/dev/vda rw",
            initramfsPath: "/images/alpine-3.18/initramfs",
            minMemory: 256 * 1024 * 1024, // 256MB
            minDisk: 1024 * 1024 * 1024, // 1GB
            maxCpu: 16,
            maxMemory: 16 * 1024 * 1024 * 1024 // 16GB
        )

        try await ubuntuTemplate.save(on: database)
        try await alpineTemplate.save(on: database)
    }

    func revert(on database: Database) async throws {
        try await VMTemplate.query(on: database).delete()
    }
}
