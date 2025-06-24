import Fluent
import Vapor
import SQLKit

struct FixVMColumnNames: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            return // Skip if not SQL database
        }
        
        // Check if memory_new exists and memory doesn't
        let hasMemoryNew = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'memory_new'").all()
        let hasMemory = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'memory'").all()
        
        if !hasMemoryNew.isEmpty && hasMemory.isEmpty {
            try await sql.raw("ALTER TABLE vms RENAME COLUMN memory_new TO memory").run()
        }
        
        // Check if disk_new exists and disk doesn't
        let hasDiskNew = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'disk_new'").all()
        let hasDisk = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'disk'").all()
        
        if !hasDiskNew.isEmpty && hasDisk.isEmpty {
            try await sql.raw("ALTER TABLE vms RENAME COLUMN disk_new TO disk").run()
        }
    }
    
    func revert(on database: Database) async throws {
        // This migration is intended to fix naming issues, revert not needed
    }
}