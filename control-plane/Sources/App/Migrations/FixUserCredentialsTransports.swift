import Fluent
import SQLKit
import SQLiteKit

struct FixUserCredentialsTransports: AsyncMigration {
    func prepare(on database: Database) async throws {
        // For SQLite (used in tests), skip this migration entirely
        // as SQLite doesn't have array types and this migration is PostgreSQL-specific
        if database is SQLiteDatabase {
            return
        }
        
        // Convert the PostgreSQL array column to a JSON string column
        let sqlDatabase = database as! SQLDatabase
        
        // Check if the transports column is already converted (TEXT type instead of TEXT[])
        let columnInfo = try await sqlDatabase.raw("""
            SELECT data_type 
            FROM information_schema.columns 
            WHERE table_name = 'user_credentials' 
            AND column_name = 'transports'
            """).all()
        
        // If column already exists as TEXT, migration is already complete
        if let firstRow = columnInfo.first {
            let dataType = try firstRow.decode(column: "data_type", as: String.self)
            if dataType == "text" {
                return
            }
        }
        
        // Drop temp column if it exists from failed previous run
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            DROP COLUMN IF EXISTS transports_temp
            """).run()
        
        // Create a temporary column
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            ADD COLUMN transports_temp TEXT
            """).run()
        
        // Convert array data to JSON string
        try await sqlDatabase.raw("""
            UPDATE user_credentials 
            SET transports_temp = COALESCE(
                array_to_json(transports)::text,
                '[]'
            )
            """).run()
        
        // Drop the old column
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            DROP COLUMN transports
            """).run()
        
        // Rename the temporary column
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            RENAME COLUMN transports_temp TO transports
            """).run()
    }
    
    func revert(on database: Database) async throws {
        // For SQLite (used in tests), skip this migration entirely
        if database is SQLiteDatabase {
            return
        }
        
        // Convert back to PostgreSQL array
        let sqlDatabase = database as! SQLDatabase
        
        // Create temporary array column
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            ADD COLUMN transports_temp TEXT[]
            """).run()
        
        // Convert JSON string to array
        try await sqlDatabase.raw("""
            UPDATE user_credentials 
            SET transports_temp = ARRAY(
                SELECT json_array_elements_text(transports::json)
            )
            """).run()
        
        // Drop the string column
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            DROP COLUMN transports
            """).run()
        
        // Rename back
        try await sqlDatabase.raw("""
            ALTER TABLE user_credentials 
            RENAME COLUMN transports_temp TO transports
            """).run()
    }
}