# Strato Development Setup

This document describes how to set up a complete local development environment for Strato, including the control-plane, agent, and all required dependencies.

## Prerequisites

### Install Task

Task is a task runner that manages all development tasks. Install it using one of these methods:

**Homebrew (Recommended)**:
```bash
brew install go-task
```

**Other Installation Methods**:
See https://taskfile.dev/installation/ for additional installation options including:
- npm: `npm install -g @go-task/cli`
- snap: `snap install task --classic`
- go: `go install github.com/go-task/task/v3/cmd/task@latest`

Verify installation:
```bash
task --version
```

## Quick Start

Start the complete development environment:

```bash
task dev
```

This will:
1. Start PostgreSQL database in Docker
2. Start SpiceDB authorization service in Docker
3. Load the SpiceDB schema
4. Build and start the control-plane
5. Build and start an agent
6. Create test user and organization data
7. Display service status and URLs

## Available Commands

List all available commands:
```bash
task --list
```

### Common Commands

**View service status**:
```bash
task status
```

**View logs**:
```bash
task logs
```

**Stop all services**:
```bash
task stop
```

**Clean up everything** (stops services and removes containers):
```bash
task clean
```

**Check running VMs**:
```bash
task check-vm
```

### Individual Service Commands
- `task dev` - Start complete development environment
- `task start-postgres` - Start PostgreSQL database
- `task start-spicedb` - Start SpiceDB authorization service
- `task load-spicedb-schema` - Load SpiceDB schema
- `task start-control-plane` - Build and start control-plane
- `task start-agent` - Build and start agent
- `task create-test-vm` - Create test VM and setup
- `task status` - Show service status
- `task logs` - Show service logs
- `task stop` - Stop all services
- `task clean` - Clean up all resources

## Service Architecture

### Infrastructure Services

#### PostgreSQL Database
- **Purpose**: Persistent storage for control-plane data
- **Container**: `strato-postgres`
- **Port**: 5432
- **Credentials**:
  - Database: `vapor_database`
  - Username: `vapor_username`
  - Password: `vapor_password`

#### SpiceDB Authorization Service
- **Purpose**: Fine-grained authorization and permissions
- **Container**: `strato-spicedb`
- **Ports**:
  - HTTP: 8081
  - gRPC: 50051
- **Pre-shared Key**: `strato-dev-key`
- **Schema**: `spicedb/schema.zed`

### Application Services

#### Control Plane
- **Purpose**: Web UI, API, and VM orchestration
- **Port**: 8080
- **Health Check**: http://localhost:8080/health/live
- **Log File**: `/tmp/strato-control-plane.log`
- **PID File**: `/tmp/strato-control-plane.pid`

#### Agent
- **Purpose**: VM management on hypervisor nodes (uses QEMU/KVM)
- **WebSocket**: Connects to control-plane at ws://localhost:8080/agent/ws
- **Log File**: `/tmp/strato-agent.log`
- **PID File**: `/tmp/strato-agent.pid`
- **Config**: `config.toml`

## Environment Variables

The scripts automatically configure these environment variables for the control-plane:

```bash
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_NAME=vapor_database
DATABASE_USERNAME=vapor_username
DATABASE_PASSWORD=vapor_password
SPICEDB_ENDPOINT=http://localhost:8081
SPICEDB_PRESHARED_KEY=strato-dev-key
WEBAUTHN_RELYING_PARTY_ID=localhost
WEBAUTHN_RELYING_PARTY_NAME=Strato
WEBAUTHN_RELYING_PARTY_ORIGIN=http://localhost:8080
```

## Test Data

The scripts automatically create:

### Test User
- **ID**: `00000000-0000-0000-0000-000000000001`
- **Username**: `admin`
- **Email**: `admin@strato.local`
- **Display Name**: `System Administrator`
- **Role**: System Admin (bypasses all permission checks)

### Test Organization
- **ID**: `00000000-0000-0000-0000-000000000001`
- **Name**: `Default Organization`

### Test Project
- **ID**: `00000000-0000-0000-0000-000000000001`
- **Name**: `Default Project`
- **Environments**: development, staging, production
- **Default Environment**: development

### Authorization Relationships
- User `admin` is an admin of the Default Organization
- Default Project belongs to Default Organization

## Creating VMs

After starting the development environment:

1. Open http://localhost:8080 in your browser
2. Register a new account (uses WebAuthn/Passkeys)
3. Complete the onboarding flow to create an organization
4. Navigate to the VMs page
5. Click "Create VM" and fill in the details:
   - Name: Your VM name
   - Description: Optional description
   - Template: Select from available templates (e.g., `ubuntu-22.04-server`)
   - Project: Select a project (or use default)
   - Environment: development, staging, or production
   - Resources: CPU, memory, disk (or use template defaults)

The VM will be automatically scheduled to the connected agent and started.

## Verifying VM Status

### Via API
```bash
# List all VMs (requires authentication)
curl -X GET http://localhost:8080/vms \
  -H "Authorization: Bearer <your-api-key>"
```

### Via Process List
```bash
# Check if QEMU is running
pgrep -a qemu
```

### Via Logs
```bash
# View agent logs to see VM operations
task logs
```

## Troubleshooting

### PostgreSQL Issues
```bash
# Check container status
docker ps -a | grep strato-postgres

# View container logs
docker logs strato-postgres

# Connect to database
docker exec -it strato-postgres psql -U vapor_username -d vapor_database
```

### SpiceDB Issues
```bash
# Check container status
docker ps -a | grep strato-spicedb

# View container logs
docker logs strato-spicedb

# Check health
curl http://localhost:8081/healthz
```

### Control Plane Issues
```bash
# View logs
tail -f /tmp/strato-control-plane.log

# Check if running
ps aux | grep "swift run"

# Check health endpoint
curl http://localhost:8080/health/live
```

### Agent Issues
```bash
# View logs
tail -f /tmp/strato-agent.log

# Check if running
ps aux | grep StratoAgent

# Verify QEMU socket directory
ls -la /tmp/strato-qemu-sockets
```

### Docker Permission Issues
If you get Docker permission errors:
```bash
sudo usermod -aG docker $USER
# Log out and back in for changes to take effect
```

### QEMU/KVM Issues
Ensure KVM is available:
```bash
# Check if KVM module is loaded
lsmod | grep kvm

# Check KVM device permissions
ls -la /dev/kvm
```

## Cleaning Up

### Stop Services
```bash
task stop
```

This stops all services but keeps data in Docker containers.

### Complete Cleanup
```bash
task clean
```

This stops all services, removes Docker containers, and cleans up log files.

### Manual Cleanup
```bash
# Remove containers
docker rm -f strato-postgres strato-spicedb

# Remove PID files
rm -f /tmp/strato-control-plane.pid /tmp/strato-agent.pid

# Remove log files
rm -f /tmp/strato-control-plane.log /tmp/strato-agent.log

# Remove config file
rm -f config.toml
```

## Development Workflow

### Typical Workflow
```bash
# 1. Start development environment
task dev

# 2. Make code changes in your editor

# 3. Stop services
task stop

# 4. Restart to test changes
task dev

# 5. View logs to debug
task logs

# 6. Check service status
task status

# 7. Clean up when done
task clean
```

### Hot Reload Development

For faster iteration, you can use Skaffold + Helm instead:
```bash
# See CLAUDE.md for Skaffold development instructions
minikube start
cd helm/strato && helm dependency build
skaffold dev --profile=minimal
```

## Next Steps

- Read [CLAUDE.md](./CLAUDE.md) for full project documentation
- Review [API documentation](http://localhost:8080/api/docs) when control-plane is running
- Check [docs/SCHEDULER.md](./docs/SCHEDULER.md) for VM scheduling details
- Explore the SpiceDB schema in [spicedb/schema.zed](./spicedb/schema.zed)

## Support

For issues or questions:
- Check logs using `task logs`
- Check status using `task status`
- Review troubleshooting section above
- Open an issue on GitHub
