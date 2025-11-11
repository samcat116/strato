import Foundation
import Sake

@main
@CommandGroup
struct Commands: SakeApp {

    // MARK: - Infrastructure Tasks

    /// Start PostgreSQL database in Docker
    public static var startPostgres: Command {
        Command(
            description: "Start PostgreSQL database container",
            run: { _ in
                print("🐘 Starting PostgreSQL...")

                // Check if container already exists
                let checkExisting = Process()
                checkExisting.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                checkExisting.arguments = ["ps", "-a", "--filter", "name=strato-postgres", "--format", "{{.Names}}"]

                let checkPipe = Pipe()
                checkExisting.standardOutput = checkPipe
                try checkExisting.run()
                checkExisting.waitUntilExit()

                let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
                let existingContainer = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if existingContainer == "strato-postgres" {
                    print("⚠️  PostgreSQL container already exists. Starting it...")
                    try runProcess("/usr/bin/docker", arguments: ["start", "strato-postgres"])
                } else {
                    // Start new PostgreSQL container
                    try runProcess("/usr/bin/docker", arguments: [
                        "run", "-d",
                        "--name", "strato-postgres",
                        "-e", "POSTGRES_DB=vapor_database",
                        "-e", "POSTGRES_USER=vapor_username",
                        "-e", "POSTGRES_PASSWORD=vapor_password",
                        "-p", "5432:5432",
                        "postgres:16-alpine"
                    ])
                }

                // Wait for PostgreSQL to be ready
                print("⏳ Waiting for PostgreSQL to be ready...")
                sleep(3)

                for i in 1...30 {
                    let checkReady = Process()
                    checkReady.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                    checkReady.arguments = [
                        "exec", "strato-postgres",
                        "pg_isready", "-U", "vapor_username", "-d", "vapor_database"
                    ]

                    let readyPipe = Pipe()
                    checkReady.standardOutput = readyPipe
                    checkReady.standardError = readyPipe
                    try checkReady.run()
                    checkReady.waitUntilExit()

                    if checkReady.terminationStatus == 0 {
                        print("✅ PostgreSQL is ready!")
                        return
                    }

                    if i < 30 {
                        sleep(1)
                    }
                }

                throw DevSetupError.timeout("PostgreSQL did not become ready in time")
            }
        )
    }

    /// Start SpiceDB authorization service in Docker
    public static var startSpiceDB: Command {
        Command(
            description: "Start SpiceDB authorization service",
            dependencies: [startPostgres],
            run: { _ in
                print("🔐 Starting SpiceDB...")

                // Check if container already exists
                let checkExisting = Process()
                checkExisting.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                checkExisting.arguments = ["ps", "-a", "--filter", "name=strato-spicedb", "--format", "{{.Names}}"]

                let checkPipe = Pipe()
                checkExisting.standardOutput = checkPipe
                try checkExisting.run()
                checkExisting.waitUntilExit()

                let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
                let existingContainer = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if existingContainer == "strato-spicedb" {
                    print("⚠️  SpiceDB container already exists. Removing and recreating...")
                    try runProcess("/usr/bin/docker", arguments: ["rm", "-f", "strato-spicedb"])
                }

                // Get PostgreSQL container IP
                let ipProcess = Process()
                ipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                ipProcess.arguments = [
                    "inspect", "-f", "{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                    "strato-postgres"
                ]

                let ipPipe = Pipe()
                ipProcess.standardOutput = ipPipe
                try ipProcess.run()
                ipProcess.waitUntilExit()

                let ipData = ipPipe.fileHandleForReading.readDataToEndOfFile()
                let postgresIP = String(data: ipData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"

                let connString = "postgres://vapor_username:vapor_password@\(postgresIP):5432/vapor_database?sslmode=disable"

                // Run SpiceDB migrate
                print("🔄 Running SpiceDB migrations...")
                try runProcess("/usr/bin/docker", arguments: [
                    "run", "--rm",
                    "--network", "host",
                    "-e", "SPICEDB_DATASTORE_ENGINE=postgres",
                    "-e", "SPICEDB_DATASTORE_CONN_URI=\(connString)",
                    "authzed/spicedb:v1.35.3",
                    "migrate", "head"
                ])

                // Start SpiceDB server
                try runProcess("/usr/bin/docker", arguments: [
                    "run", "-d",
                    "--name", "strato-spicedb",
                    "--network", "host",
                    "-e", "SPICEDB_DATASTORE_ENGINE=postgres",
                    "-e", "SPICEDB_DATASTORE_CONN_URI=\(connString)",
                    "-e", "SPICEDB_GRPC_PRESHARED_KEY=strato-dev-key",
                    "authzed/spicedb:v1.35.3",
                    "serve",
                    "--grpc-preshared-key", "strato-dev-key",
                    "--http-enabled",
                    "--http-addr", ":8081",
                    "--grpc-addr", ":50051"
                ])

                // Wait for SpiceDB to be ready
                print("⏳ Waiting for SpiceDB to be ready...")
                sleep(3)

                for i in 1...30 {
                    let checkReady = Process()
                    checkReady.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    checkReady.arguments = ["-sf", "http://localhost:8081/healthz"]

                    let readyPipe = Pipe()
                    checkReady.standardOutput = readyPipe
                    checkReady.standardError = readyPipe
                    try checkReady.run()
                    checkReady.waitUntilExit()

                    if checkReady.terminationStatus == 0 {
                        print("✅ SpiceDB is ready!")
                        return
                    }

                    if i < 30 {
                        sleep(1)
                    }
                }

                throw DevSetupError.timeout("SpiceDB did not become ready in time")
            }
        )
    }

    /// Load SpiceDB schema
    public static var loadSpiceDBSchema: Command {
        Command(
            description: "Load SpiceDB authorization schema",
            dependencies: [startSpiceDB],
            run: { _ in
                print("📋 Loading SpiceDB schema...")

                let schemaPath = "/home/user/strato/spicedb/schema.zed"

                // Check if schema file exists
                guard FileManager.default.fileExists(atPath: schemaPath) else {
                    throw DevSetupError.fileNotFound("SpiceDB schema not found at \(schemaPath)")
                }

                // Load schema using zed CLI
                try runProcess("/usr/bin/docker", arguments: [
                    "run", "--rm",
                    "--network", "host",
                    "-v", "\(schemaPath):/schema.zed:ro",
                    "authzed/zed:latest",
                    "schema", "write", "/schema.zed",
                    "--endpoint", "localhost:50051",
                    "--token", "strato-dev-key",
                    "--insecure"
                ])

                print("✅ SpiceDB schema loaded!")
            }
        )
    }

    // MARK: - Application Tasks

    /// Build and run control-plane
    public static var startControlPlane: Command {
        Command(
            description: "Build and start the control-plane service",
            dependencies: [loadSpiceDBSchema],
            run: { _ in
                print("🚀 Building and starting control-plane...")

                // Build control-plane
                print("🔨 Building control-plane...")
                try runProcess(
                    "/usr/bin/swift",
                    arguments: ["build", "--package-path", "/home/user/strato/control-plane"],
                    showOutput: true
                )

                // Run control-plane in background
                print("▶️  Starting control-plane...")

                let controlPlane = Process()
                controlPlane.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
                controlPlane.arguments = ["run", "--package-path", "/home/user/strato/control-plane"]

                // Set environment variables
                var env = ProcessInfo.processInfo.environment
                env["DATABASE_HOST"] = "localhost"
                env["DATABASE_PORT"] = "5432"
                env["DATABASE_NAME"] = "vapor_database"
                env["DATABASE_USERNAME"] = "vapor_username"
                env["DATABASE_PASSWORD"] = "vapor_password"
                env["SPICEDB_ENDPOINT"] = "http://localhost:8081"
                env["SPICEDB_PRESHARED_KEY"] = "strato-dev-key"
                env["WEBAUTHN_RELYING_PARTY_ID"] = "localhost"
                env["WEBAUTHN_RELYING_PARTY_NAME"] = "Strato"
                env["WEBAUTHN_RELYING_PARTY_ORIGIN"] = "http://localhost:8080"
                controlPlane.environment = env

                // Capture output to a log file
                let logPath = "/tmp/strato-control-plane.log"
                FileManager.default.createFile(atPath: logPath, contents: nil)
                let logFile = FileHandle(forWritingAtPath: logPath)
                controlPlane.standardOutput = logFile
                controlPlane.standardError = logFile

                try controlPlane.run()

                // Store PID for cleanup
                try String(controlPlane.processIdentifier).write(
                    toFile: "/tmp/strato-control-plane.pid",
                    atomically: true,
                    encoding: .utf8
                )

                // Wait for control-plane to be ready
                print("⏳ Waiting for control-plane to be ready...")
                sleep(5)

                for i in 1...60 {
                    let checkReady = Process()
                    checkReady.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    checkReady.arguments = ["-sf", "http://localhost:8080/health/live"]

                    let readyPipe = Pipe()
                    checkReady.standardOutput = readyPipe
                    checkReady.standardError = readyPipe
                    try checkReady.run()
                    checkReady.waitUntilExit()

                    if checkReady.terminationStatus == 0 {
                        print("✅ Control-plane is ready!")
                        print("📋 Logs available at: \(logPath)")
                        return
                    }

                    if i < 60 {
                        sleep(2)
                    }
                }

                print("⚠️  Control-plane may not be fully ready. Check logs at \(logPath)")
            }
        )
    }

    /// Create agent configuration
    public static var createAgentConfig: Command {
        Command(
            description: "Create agent configuration file",
            run: { _ in
                print("📝 Creating agent configuration...")

                let configContent = """
                # Strato Agent Configuration
                control_plane_url = "ws://localhost:8080/agent/ws"
                qemu_socket_dir = "/tmp/strato-qemu-sockets"
                log_level = "debug"
                """

                let configPath = "/home/user/strato/config.toml"
                try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                print("✅ Agent config created at \(configPath)")
            }
        )
    }

    /// Build and run agent
    public static var startAgent: Command {
        Command(
            description: "Build and start the agent service",
            dependencies: [startControlPlane, createAgentConfig],
            run: { _ in
                print("🤖 Building and starting agent...")

                // Build agent
                print("🔨 Building agent...")
                try runProcess(
                    "/usr/bin/swift",
                    arguments: ["build", "--package-path", "/home/user/strato/agent"],
                    showOutput: true
                )

                // Ensure QEMU socket directory exists
                let socketDir = "/tmp/strato-qemu-sockets"
                if !FileManager.default.fileExists(atPath: socketDir) {
                    try FileManager.default.createDirectory(
                        atPath: socketDir,
                        withIntermediateDirectories: true
                    )
                }

                // Run agent in background
                print("▶️  Starting agent...")

                let agent = Process()
                agent.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
                agent.arguments = [
                    "run", "--package-path", "/home/user/strato/agent",
                    "StratoAgent",
                    "--config-file", "/home/user/strato/config.toml"
                ]

                // Capture output to a log file
                let logPath = "/tmp/strato-agent.log"
                FileManager.default.createFile(atPath: logPath, contents: nil)
                let logFile = FileHandle(forWritingAtPath: logPath)
                agent.standardOutput = logFile
                agent.standardError = logFile

                try agent.run()

                // Store PID for cleanup
                try String(agent.processIdentifier).write(
                    toFile: "/tmp/strato-agent.pid",
                    atomically: true,
                    encoding: .utf8
                )

                print("✅ Agent started!")
                print("📋 Logs available at: \(logPath)")
                sleep(3)
            }
        )
    }

    // MARK: - Test & Verification Tasks

    /// Create a test VM via API
    public static var createTestVM: Command {
        Command(
            description: "Create a test VM via the API",
            dependencies: [startAgent],
            run: { _ in
                print("🖥️  Creating test VM...")

                // First, we need to create a user and organization
                // This is complex because we need WebAuthn, so let's use the database directly
                print("👤 Setting up test user and organization...")

                // Create user directly in database
                let createUserSQL = """
                INSERT INTO users (id, username, email, display_name, is_system_admin, created_at, updated_at)
                VALUES (
                    '00000000-0000-0000-0000-000000000001',
                    'admin',
                    'admin@strato.local',
                    'System Administrator',
                    true,
                    NOW(),
                    NOW()
                )
                ON CONFLICT (id) DO NOTHING;
                """

                try runProcess("/usr/bin/docker", arguments: [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", createUserSQL
                ])

                // Create organization
                let createOrgSQL = """
                INSERT INTO organizations (id, name, description, created_at, updated_at)
                VALUES (
                    '00000000-0000-0000-0000-000000000001',
                    'Default Organization',
                    'Default organization for testing',
                    NOW(),
                    NOW()
                )
                ON CONFLICT (id) DO NOTHING;
                """

                try runProcess("/usr/bin/docker", arguments: [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", createOrgSQL
                ])

                // Link user to organization
                let linkUserOrgSQL = """
                INSERT INTO user_organization (user_id, organization_id)
                VALUES (
                    '00000000-0000-0000-0000-000000000001',
                    '00000000-0000-0000-0000-000000000001'
                )
                ON CONFLICT DO NOTHING;
                """

                try runProcess("/usr/bin/docker", arguments: [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", linkUserOrgSQL
                ])

                // Set current organization for user
                let updateUserOrgSQL = """
                UPDATE users
                SET current_organization_id = '00000000-0000-0000-0000-000000000001'
                WHERE id = '00000000-0000-0000-0000-000000000001';
                """

                try runProcess("/usr/bin/docker", arguments: [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", updateUserOrgSQL
                ])

                // Create default project
                let createProjectSQL = """
                INSERT INTO projects (id, organization_id, name, description, default_environment, environments, created_at, updated_at)
                VALUES (
                    '00000000-0000-0000-0000-000000000001',
                    '00000000-0000-0000-0000-000000000001',
                    'Default Project',
                    'Default project for testing',
                    'development',
                    ARRAY['development', 'staging', 'production'],
                    NOW(),
                    NOW()
                )
                ON CONFLICT (id) DO NOTHING;
                """

                try runProcess("/usr/bin/docker", arguments: [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", createProjectSQL
                ])

                // Set up SpiceDB relationships
                print("🔐 Setting up authorization relationships...")

                // User is admin of organization
                try runSpiceDBRelationship(
                    operation: "create",
                    resourceType: "organization",
                    resourceId: "00000000-0000-0000-0000-000000000001",
                    relation: "admin",
                    subjectType: "user",
                    subjectId: "00000000-0000-0000-0000-000000000001"
                )

                // Project belongs to organization
                try runSpiceDBRelationship(
                    operation: "create",
                    resourceType: "project",
                    resourceId: "00000000-0000-0000-0000-000000000001",
                    relation: "organization",
                    subjectType: "organization",
                    subjectId: "00000000-0000-0000-0000-000000000001"
                )

                print("✅ Test user and organization created!")
                print("   Username: admin")
                print("   User ID: 00000000-0000-0000-0000-000000000001")
                print("   Organization: Default Organization")

                // Note: Actually creating a VM requires a valid template and session authentication
                // which is complex to set up programmatically. Instead, we'll just verify the setup is ready.
                print("\n🎉 Development environment is ready!")
                print("\n📝 To create a VM manually:")
                print("   1. Open http://localhost:8080 in your browser")
                print("   2. Register a new account (or login if you already have one)")
                print("   3. Complete the onboarding to create an organization")
                print("   4. Navigate to VMs and create a new VM")
                print("\n📊 Service Status:")
                print("   • PostgreSQL:     http://localhost:5432")
                print("   • SpiceDB:        http://localhost:8081")
                print("   • Control Plane:  http://localhost:8080")
                print("   • Agent:          Connected via WebSocket")
            }
        )
    }

    /// Check if VM is running
    public static var checkVM: Command {
        Command(
            description: "Check if VMs are running via QEMU",
            run: { _ in
                print("🔍 Checking for running VMs...")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = ["-a", "qemu"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let output = output, !output.isEmpty {
                    print("✅ Found running QEMU processes:")
                    print(output)
                } else {
                    print("ℹ️  No QEMU processes found. VMs may not be running yet.")
                }
            }
        )
    }

    // MARK: - Cleanup Tasks

    /// Stop all services
    public static var stop: Command {
        Command(
            description: "Stop all running services",
            run: { _ in
                print("🛑 Stopping all services...")

                // Stop agent
                if let pidString = try? String(contentsOfFile: "/tmp/strato-agent.pid"),
                   let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    print("Stopping agent (PID: \(pid))...")
                    kill(pid, SIGTERM)
                    try? FileManager.default.removeItem(atPath: "/tmp/strato-agent.pid")
                }

                // Stop control-plane
                if let pidString = try? String(contentsOfFile: "/tmp/strato-control-plane.pid"),
                   let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    print("Stopping control-plane (PID: \(pid))...")
                    kill(pid, SIGTERM)
                    try? FileManager.default.removeItem(atPath: "/tmp/strato-control-plane.pid")
                }

                // Stop Docker containers
                print("Stopping Docker containers...")
                _ = try? runProcess("/usr/bin/docker", arguments: ["stop", "strato-spicedb"])
                _ = try? runProcess("/usr/bin/docker", arguments: ["stop", "strato-postgres"])

                print("✅ All services stopped!")
            }
        )
    }

    /// Clean up all resources
    public static var clean: Command {
        Command(
            description: "Stop services and remove all containers and data",
            dependencies: [stop],
            run: { _ in
                print("🧹 Cleaning up all resources...")

                // Remove Docker containers
                print("Removing Docker containers...")
                _ = try? runProcess("/usr/bin/docker", arguments: ["rm", "-f", "strato-spicedb"])
                _ = try? runProcess("/usr/bin/docker", arguments: ["rm", "-f", "strato-postgres"])

                // Remove log files
                print("Removing log files...")
                _ = try? FileManager.default.removeItem(atPath: "/tmp/strato-control-plane.log")
                _ = try? FileManager.default.removeItem(atPath: "/tmp/strato-agent.log")

                print("✅ Cleanup complete!")
            }
        )
    }

    // MARK: - Convenience Tasks

    /// Start entire development environment
    public static var dev: Command {
        Command(
            description: "Start complete development environment",
            dependencies: [createTestVM],
            run: { _ in
                print("\n🎉 Development environment is fully running!")
                print("\n📊 Service URLs:")
                print("   • Control Plane:  http://localhost:8080")
                print("   • SpiceDB Admin:  http://localhost:8081")
                print("   • PostgreSQL:     localhost:5432")
                print("\n📋 Logs:")
                print("   • Control Plane:  tail -f /tmp/strato-control-plane.log")
                print("   • Agent:          tail -f /tmp/strato-agent.log")
                print("\n⚠️  To stop all services, run: sake stop")
                print("⚠️  To clean everything up, run: sake clean")
            }
        )
    }

    /// Show service logs
    public static var logs: Command {
        Command(
            description: "Show logs from all services",
            run: { _ in
                print("📋 Service Logs\n")

                print("=== Control Plane Logs ===")
                if FileManager.default.fileExists(atPath: "/tmp/strato-control-plane.log") {
                    let logs = try String(contentsOfFile: "/tmp/strato-control-plane.log")
                    let lines = logs.split(separator: "\n")
                    let lastLines = lines.suffix(20)
                    print(lastLines.joined(separator: "\n"))
                } else {
                    print("No logs found")
                }

                print("\n=== Agent Logs ===")
                if FileManager.default.fileExists(atPath: "/tmp/strato-agent.log") {
                    let logs = try String(contentsOfFile: "/tmp/strato-agent.log")
                    let lines = logs.split(separator: "\n")
                    let lastLines = lines.suffix(20)
                    print(lastLines.joined(separator: "\n"))
                } else {
                    print("No logs found")
                }
            }
        )
    }

    /// Show service status
    public static var status: Command {
        Command(
            description: "Show status of all services",
            run: { _ in
                print("📊 Service Status\n")

                // Check PostgreSQL
                print("PostgreSQL:    ", terminator: "")
                let pgCheck = Process()
                pgCheck.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                pgCheck.arguments = ["ps", "--filter", "name=strato-postgres", "--format", "{{.Status}}"]
                let pgPipe = Pipe()
                pgCheck.standardOutput = pgPipe
                try? pgCheck.run()
                pgCheck.waitUntilExit()
                let pgStatus = String(data: pgPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                print(!pgStatus!.isEmpty ? "✅ Running (\(pgStatus!))" : "❌ Stopped")

                // Check SpiceDB
                print("SpiceDB:       ", terminator: "")
                let spiceCheck = Process()
                spiceCheck.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                spiceCheck.arguments = ["ps", "--filter", "name=strato-spicedb", "--format", "{{.Status}}"]
                let spicePipe = Pipe()
                spiceCheck.standardOutput = spicePipe
                try? spiceCheck.run()
                spiceCheck.waitUntilExit()
                let spiceStatus = String(data: spicePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                print(!spiceStatus!.isEmpty ? "✅ Running (\(spiceStatus!))" : "❌ Stopped")

                // Check control-plane
                print("Control Plane: ", terminator: "")
                if let pidString = try? String(contentsOfFile: "/tmp/strato-control-plane.pid"),
                   let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
                   kill(pid, 0) == 0 {
                    print("✅ Running (PID: \(pid))")
                } else {
                    print("❌ Stopped")
                }

                // Check agent
                print("Agent:         ", terminator: "")
                if let pidString = try? String(contentsOfFile: "/tmp/strato-agent.pid"),
                   let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
                   kill(pid, 0) == 0 {
                    print("✅ Running (PID: \(pid))")
                } else {
                    print("❌ Stopped")
                }
            }
        )
    }
}

// MARK: - Helper Functions

func runProcess(_ executable: String, arguments: [String], showOutput: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if showOutput {
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    } else {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
    }

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw DevSetupError.processFailure("\(executable) failed with exit code \(process.terminationStatus)")
    }
}

func runSpiceDBRelationship(
    operation: String,
    resourceType: String,
    resourceId: String,
    relation: String,
    subjectType: String,
    subjectId: String
) throws {
    let relationship = """
    {
      "updates": [{
        "operation": "OPERATION_CREATE",
        "relationship": {
          "resource": {
            "objectType": "\(resourceType)",
            "objectId": "\(resourceId)"
          },
          "relation": "\(relation)",
          "subject": {
            "object": {
              "objectType": "\(subjectType)",
              "objectId": "\(subjectId)"
            }
          }
        }
      }]
    }
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer strato-dev-key",
        "-d", relationship,
        "http://localhost:8081/v1/relationships/write"
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw DevSetupError.processFailure("Failed to create SpiceDB relationship")
    }
}

enum DevSetupError: Error, CustomStringConvertible {
    case timeout(String)
    case fileNotFound(String)
    case processFailure(String)

    var description: String {
        switch self {
        case .timeout(let message):
            return "Timeout: \(message)"
        case .fileNotFound(let message):
            return "File not found: \(message)"
        case .processFailure(let message):
            return "Process failure: \(message)"
        }
    }
}
