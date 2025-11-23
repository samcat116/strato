import Foundation
import Sake

// Get the project root directory dynamically
let projectRoot = FileManager.default.currentDirectoryPath

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

    /// Start Valkey (Redis alternative) in Docker
    public static var startValkey: Command {
        Command(
            description: "Start Valkey cache container",
            run: { _ in
                print("🔴 Starting Valkey...")

                // Check if container already exists
                let checkExisting = Process()
                checkExisting.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                checkExisting.arguments = ["ps", "-a", "--filter", "name=strato-valkey", "--format", "{{.Names}}"]

                let checkPipe = Pipe()
                checkExisting.standardOutput = checkPipe
                try checkExisting.run()
                checkExisting.waitUntilExit()

                let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
                let existingContainer = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if existingContainer == "strato-valkey" {
                    print("⚠️  Valkey container already exists. Starting it...")
                    try runProcess("/usr/bin/docker", arguments: ["start", "strato-valkey"])
                } else {
                    // Start new Valkey container
                    try runProcess("/usr/bin/docker", arguments: [
                        "run", "-d",
                        "--name", "strato-valkey",
                        "-e", "VALKEY_PASSWORD=valkey_password",
                        "-p", "6379:6379",
                        "-v", "strato-valkey-data:/data",
                        "valkey/valkey:latest",
                        "valkey-server", "--requirepass", "valkey_password", "--appendonly", "yes"
                    ])
                }

                // Wait for Valkey to be ready
                print("⏳ Waiting for Valkey to be ready...")
                sleep(2)

                for i in 1...30 {
                    let checkReady = Process()
                    checkReady.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                    checkReady.arguments = [
                        "exec", "strato-valkey",
                        "valkey-cli", "-a", "valkey_password", "ping"
                    ]

                    let readyPipe = Pipe()
                    checkReady.standardOutput = readyPipe
                    checkReady.standardError = readyPipe
                    try checkReady.run()
                    checkReady.waitUntilExit()

                    let readyData = readyPipe.fileHandleForReading.readDataToEndOfFile()
                    let response = String(data: readyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    if checkReady.terminationStatus == 0 && response == "PONG" {
                        print("✅ Valkey is ready!")
                        return
                    }

                    if i < 30 {
                        sleep(1)
                    }
                }

                throw DevSetupError.timeout("Valkey did not become ready in time")
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

                let schemaPath = "\(projectRoot)/spicedb/schema.zed"

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
            dependencies: [loadSpiceDBSchema, startValkey],
            run: { _ in
                print("🚀 Building and starting control-plane...")

                // Build control-plane
                print("🔨 Building control-plane...")
                try runProcess(
                    findSwiftExecutable(),
                    arguments: ["build", "--package-path", "\(projectRoot)/control-plane"],
                    showOutput: true
                )

                // Run control-plane in background
                print("▶️  Starting control-plane...")

                let controlPlane = Process()
                controlPlane.executableURL = URL(fileURLWithPath: findSwiftExecutable())
                controlPlane.arguments = ["run", "--package-path", "\(projectRoot)/control-plane"]

                // Set environment variables
                var env = ProcessInfo.processInfo.environment
                env["DATABASE_HOST"] = "localhost"
                env["DATABASE_PORT"] = "5432"
                env["DATABASE_NAME"] = "vapor_database"
                env["DATABASE_USERNAME"] = "vapor_username"
                env["DATABASE_PASSWORD"] = "vapor_password"
                env["REDIS_HOST"] = "localhost"
                env["REDIS_PORT"] = "6379"
                env["REDIS_PASSWORD"] = "valkey_password"
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
                network_mode = "user"
                """

                let configPath = "\(projectRoot)/config.toml"
                try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                print("✅ Agent config created at \(configPath)")
            }
        )
    }

    /// Create agent registration token
    public static var createAgentRegistrationToken: Command {
        Command(
            description: "Create agent registration token in database",
            dependencies: [startControlPlane],
            run: { _ in
                print("🔑 Creating agent registration token...")

                let agentName = "strato-dev"
                let tokenValue = UUID().uuidString

                // Create registration token in database
                let createTokenSQL = """
                INSERT INTO agent_registration_tokens (id, token, agent_name, is_used, expires_at, created_at)
                VALUES (
                    gen_random_uuid(),
                    '\(tokenValue)',
                    '\(agentName)',
                    false,
                    NOW() + INTERVAL '24 hours',
                    NOW()
                )
                ON CONFLICT DO NOTHING;
                """

                let createTokenProcess = Process()
                createTokenProcess.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                createTokenProcess.arguments = [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-c", createTokenSQL
                ]

                let tokenPipe = Pipe()
                createTokenProcess.standardOutput = tokenPipe
                createTokenProcess.standardError = tokenPipe

                do {
                    try createTokenProcess.run()
                    createTokenProcess.waitUntilExit()
                } catch {
                    print("⚠️  Failed to create agent registration token: \(error)")
                }

                // Store the registration URL for the agent to use
                let registrationURL = "ws://localhost:8080/agent/ws?token=\(tokenValue)&name=\(agentName)"
                try registrationURL.write(
                    toFile: "/tmp/strato-agent-registration-url.txt",
                    atomically: true,
                    encoding: .utf8
                )

                print("✅ Agent registration token created!")
                print("   Agent name: \(agentName)")
                print("   Registration URL saved to /tmp/strato-agent-registration-url.txt")
            }
        )
    }

    /// Build and run agent
    public static var startAgent: Command {
        Command(
            description: "Build and start the agent service",
            dependencies: [createAgentConfig, createAgentRegistrationToken],
            run: { _ in
                print("🤖 Building and starting agent...")

                // Build agent
                print("🔨 Building agent...")
                try runProcess(
                    findSwiftExecutable(),
                    arguments: ["build", "--package-path", "\(projectRoot)/agent"],
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

                // Read registration URL
                let registrationURLPath = "/tmp/strato-agent-registration-url.txt"
                guard let registrationURL = try? String(contentsOfFile: registrationURLPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw DevSetupError.fileNotFound("Agent registration URL not found at \(registrationURLPath)")
                }

                // Run agent in background
                print("▶️  Starting agent with registration URL...")

                let agent = Process()
                agent.executableURL = URL(fileURLWithPath: findSwiftExecutable())
                agent.arguments = [
                    "run", "--package-path", "\(projectRoot)/agent",
                    "StratoAgent",
                    "--config-file", "\(projectRoot)/config.toml",
                    "--registration-url", registrationURL
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
                sleep(5) // Give agent more time to register
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
                ON CONFLICT (username) DO NOTHING;
                """

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", createUserSQL
                    ])
                } catch {
                    print("⚠️  Failed to create user in database: \(error)")
                }

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

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", createOrgSQL
                    ])
                } catch {
                    print("⚠️  Failed to create organization in database: \(error)")
                }

                // Link user to organization
                let linkUserOrgSQL = """
                INSERT INTO user_organizations (user_id, organization_id)
                VALUES (
                    '00000000-0000-0000-0000-000000000001',
                    '00000000-0000-0000-0000-000000000001'
                )
                ON CONFLICT DO NOTHING;
                """

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", linkUserOrgSQL
                    ])
                } catch {
                    print("⚠️  Failed to link user to organization: \(error)")
                }

                // Set current organization for user
                let updateUserOrgSQL = """
                UPDATE users
                SET current_organization_id = '00000000-0000-0000-0000-000000000001'
                WHERE id = '00000000-0000-0000-0000-000000000001';
                """

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", updateUserOrgSQL
                    ])
                } catch {
                    print("⚠️  Failed to set current organization for user: \(error)")
                }

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

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", createProjectSQL
                    ])
                } catch {
                    print("⚠️  Failed to create project in database: \(error)")
                }

                // Set up SpiceDB relationships
                print("🔐 Setting up authorization relationships...")

                // User is admin of organization
                try? runSpiceDBRelationship(
                    resourceType: "organization",
                    resourceId: "00000000-0000-0000-0000-000000000001",
                    relation: "admin",
                    subjectType: "user",
                    subjectId: "00000000-0000-0000-0000-000000000001"
                )

                // Project belongs to organization
                try? runSpiceDBRelationship(
                    resourceType: "project",
                    resourceId: "00000000-0000-0000-0000-000000000001",
                    relation: "organization",
                    subjectType: "organization",
                    subjectId: "00000000-0000-0000-0000-000000000001"
                )

                print("✅ Test user and organization created!")

                // Get the actual user ID from the database
                let getUserIDProcess = Process()
                getUserIDProcess.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                getUserIDProcess.arguments = [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-t", "-A", "-c", "SELECT id FROM users WHERE username = 'admin' LIMIT 1;"
                ]
                let userIDPipe = Pipe()
                getUserIDProcess.standardOutput = userIDPipe
                try getUserIDProcess.run()
                getUserIDProcess.waitUntilExit()

                let userIDData = userIDPipe.fileHandleForReading.readDataToEndOfFile()
                let actualUserID = String(data: userIDData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "00000000-0000-0000-0000-000000000001"

                print("   Username: admin")
                print("   User ID: \(actualUserID)")
                print("   Organization: Default Organization")

                // Create an API key for the admin user to make API calls
                print("\n🔑 Creating API key for admin user...")

                // Generate API key components
                let apiKeyValue = "sk_dev_test_key_\(UUID().uuidString.prefix(32))"
                let keyPrefix = String(apiKeyValue.prefix(16))

                // Hash the key for storage using sha256sum
                let hashProcess = Process()
                hashProcess.executableURL = URL(fileURLWithPath: "/usr/bin/bash")
                hashProcess.arguments = ["-c", "echo -n '\(apiKeyValue)' | sha256sum | cut -d' ' -f1"]
                let hashPipe = Pipe()
                hashProcess.standardOutput = hashPipe
                try hashProcess.run()
                hashProcess.waitUntilExit()

                let hashData = hashPipe.fileHandleForReading.readDataToEndOfFile()
                let keyHash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Delete any existing test API key first
                let deleteOldKeySQL = "DELETE FROM api_keys WHERE name = 'Development Test Key';"
                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", deleteOldKeySQL
                    ])
                } catch {
                    print("⚠️  Failed to delete old API key: \(error)")
                }

                let createAPIKeySQL = """
                INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, scopes, is_active, created_at, updated_at)
                VALUES (
                    gen_random_uuid(),
                    '\(actualUserID)',
                    'Development Test Key',
                    '\(keyHash)',
                    '\(keyPrefix)',
                    ARRAY['read', 'write'],
                    true,
                    NOW(),
                    NOW()
                );
                """

                do {
                    try runProcess("/usr/bin/docker", arguments: [
                        "exec", "strato-postgres",
                        "psql", "-U", "vapor_username", "-d", "vapor_database",
                        "-c", createAPIKeySQL
                    ])
                } catch {
                    print("⚠️  Failed to create API key in database: \(error)")
                }

                print("✅ API key created!")

                // Get the user's current organization ID
                let getOrgIDProcess = Process()
                getOrgIDProcess.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                getOrgIDProcess.arguments = [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-t", "-A", "-c", "SELECT current_organization_id FROM users WHERE username = 'admin' LIMIT 1;"
                ]
                let orgIDPipe = Pipe()
                getOrgIDProcess.standardOutput = orgIDPipe
                try getOrgIDProcess.run()
                getOrgIDProcess.waitUntilExit()

                let orgIDData = orgIDPipe.fileHandleForReading.readDataToEndOfFile()
                let orgID = String(data: orgIDData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Get the default project ID for this organization
                let getProjectIDProcess = Process()
                getProjectIDProcess.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                getProjectIDProcess.arguments = [
                    "exec", "strato-postgres",
                    "psql", "-U", "vapor_username", "-d", "vapor_database",
                    "-t", "-A", "-c", "SELECT id FROM projects WHERE organization_id = '\(orgID)' LIMIT 1;"
                ]
                let projectIDPipe = Pipe()
                getProjectIDProcess.standardOutput = projectIDPipe
                try getProjectIDProcess.run()
                getProjectIDProcess.waitUntilExit()

                let projectIDData = projectIDPipe.fileHandleForReading.readDataToEndOfFile()
                let projectID = String(data: projectIDData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Create a test VM via the API
                print("\n🖥️  Creating test VM via API...")

                let vmCreatePayload = """
                {
                    "name": "test-vm-\(UUID().uuidString.prefix(8))",
                    "description": "Test VM created by sake dev",
                    "templateName": "ubuntu-22.04",
                    "projectId": "\(projectID)",
                    "environment": "development"
                }
                """

                // Save payload to temp file
                let payloadPath = "/tmp/vm-create-payload.json"
                try vmCreatePayload.write(toFile: payloadPath, atomically: true, encoding: .utf8)

                // Make API request to create VM
                let curlProcess = Process()
                curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curlProcess.arguments = [
                    "-X", "POST",
                    "-H", "Content-Type: application/json",
                    "-H", "Authorization: Bearer \(apiKeyValue)",
                    "-d", "@\(payloadPath)",
                    "-s",
                    "http://localhost:8080/vms"
                ]

                let curlPipe = Pipe()
                curlProcess.standardOutput = curlPipe
                curlProcess.standardError = curlPipe

                try curlProcess.run()
                curlProcess.waitUntilExit()

                let responseData = curlPipe.fileHandleForReading.readDataToEndOfFile()
                let responseString = String(data: responseData, encoding: .utf8) ?? ""

                if curlProcess.terminationStatus == 0 && !responseString.isEmpty {
                    print("✅ VM created successfully!")
                    print("   Response: \(responseString.prefix(200))...")
                } else {
                    print("⚠️  VM creation may have failed. Response: \(responseString)")
                }

                // Clean up temp file
                try? FileManager.default.removeItem(atPath: payloadPath)

                print("\n🎉 Development environment is ready!")
                print("\n📊 Service Status:")
                print("   • PostgreSQL:     http://localhost:5432")
                print("   • Valkey (Redis): localhost:6379")
                print("   • SpiceDB:        http://localhost:8081")
                print("   • Control Plane:  http://localhost:8080")
                print("   • Agent:          Connected via WebSocket")
                print("\n📝 Next steps:")
                print("   • Check VM status: sake checkVM")
                print("   • View logs: sake logs")
                print("   • Open web UI: http://localhost:8080")
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
                _ = try? runProcess("/usr/bin/docker", arguments: ["stop", "strato-valkey"])
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
                _ = try? runProcess("/usr/bin/docker", arguments: ["rm", "-f", "strato-valkey"])
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
                print("   • Valkey (Redis): localhost:6379")
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
                let pgStatus = String(data: pgPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print(pgStatus.isEmpty ? "❌ Stopped" : "✅ Running (\(pgStatus))")

                // Check SpiceDB
                print("SpiceDB:       ", terminator: "")
                let spiceCheck = Process()
                spiceCheck.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                spiceCheck.arguments = ["ps", "--filter", "name=strato-spicedb", "--format", "{{.Status}}"]
                let spicePipe = Pipe()
                spiceCheck.standardOutput = spicePipe
                try? spiceCheck.run()
                spiceCheck.waitUntilExit()
                let spiceStatus = String(data: spicePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print(spiceStatus.isEmpty ? "❌ Stopped" : "✅ Running (\(spiceStatus))")

                // Check Valkey
                print("Valkey:        ", terminator: "")
                let valkeyCheck = Process()
                valkeyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/docker")
                valkeyCheck.arguments = ["ps", "--filter", "name=strato-valkey", "--format", "{{.Status}}"]
                let valkeyPipe = Pipe()
                valkeyCheck.standardOutput = valkeyPipe
                try? valkeyCheck.run()
                valkeyCheck.waitUntilExit()
                let valkeyStatus = String(data: valkeyPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print(valkeyStatus.isEmpty ? "❌ Stopped" : "✅ Running (\(valkeyStatus))")

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

func findSwiftExecutable() -> String {
    // Try to find swift in PATH using 'which' command
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["swift"]

    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    whichProcess.standardError = Pipe()

    do {
        try whichProcess.run()
        whichProcess.waitUntilExit()

        if whichProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }
    } catch {
        // Fall through to defaults
    }

    // Fallback to common locations
    let commonPaths = [
        "/usr/bin/swift",
        "/usr/local/bin/swift"
    ]

    for path in commonPaths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }

    // Last resort - hope it's in PATH
    return "swift"
}

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
