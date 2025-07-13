import Fluent
import Vapor
import SQLKit
import FluentSQLiteDriver
import FluentPostgresDriver

struct FixVMColumnNames: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            return // Skip if not SQL database
        }
        
        // Check if we're using SQLite or PostgreSQL
        if database is SQLiteDatabase {
            // SQLite version - use PRAGMA table_info
            let tableInfo = try await sql.raw("PRAGMA table_info(vms)").all()
            
            var hasMemoryNew = false
            var hasMemory = false
            var hasDiskNew = false
            var hasDisk = false
            
            for row in tableInfo {
                if let name = try? row.decode(column: "name", as: String.self) {
                    switch name {
                    case "memory_new": hasMemoryNew = true
                    case "memory": hasMemory = true
                    case "disk_new": hasDiskNew = true
                    case "disk": hasDisk = true
                    default: break
                    }
                }
            }
            
            // SQLite doesn't support RENAME COLUMN, skip for testing
            // In SQLite testing mode, we'll just keep both columns
            if hasMemoryNew && !hasMemory {
                // try await sql.raw("ALTER TABLE vms RENAME COLUMN memory_new TO memory").run()
            }
            
            if hasDiskNew && !hasDisk {
                // try await sql.raw("ALTER TABLE vms RENAME COLUMN disk_new TO disk").run()
            }
        } else {
            // PostgreSQL version - use information_schema
            let hasMemoryNew = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'memory_new'").all()
            let hasMemory = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'memory'").all()
            
            if !hasMemoryNew.isEmpty && hasMemory.isEmpty {
                try await sql.raw("ALTER TABLE vms RENAME COLUMN memory_new TO memory").run()
            }
            
            let hasDiskNew = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'disk_new'").all()
            let hasDisk = try await sql.raw("SELECT column_name FROM information_schema.columns WHERE table_name = 'vms' AND column_name = 'disk'").all()
            
            if !hasDiskNew.isEmpty && hasDisk.isEmpty {
                try await sql.raw("ALTER TABLE vms RENAME COLUMN disk_new TO disk").run()
            }
        }
    }
    
    func revert(on database: Database) async throws {
        // This migration is intended to fix naming issues, revert not needed
    }
}