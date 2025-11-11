#!/usr/bin/env bash

# Strato Development Environment Setup Script
# This script sets up a complete local development environment with:
# - PostgreSQL database
# - SpiceDB authorization service
# - Control Plane API server
# - Agent service
# - Test data and verification

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
POSTGRES_CONTAINER="strato-postgres"
SPICEDB_CONTAINER="strato-spicedb"
DB_NAME="vapor_database"
DB_USER="vapor_username"
DB_PASSWORD="vapor_password"
SPICEDB_KEY="strato-dev-key"
CONTROL_PLANE_PORT="8080"
SPICEDB_HTTP_PORT="8081"
SPICEDB_GRPC_PORT="50051"
POSTGRES_PORT="5432"

# PID files
CONTROL_PLANE_PID="/tmp/strato-control-plane.pid"
AGENT_PID="/tmp/strato-agent.pid"

# Log files
CONTROL_PLANE_LOG="/tmp/strato-control-plane.log"
AGENT_LOG="/tmp/strato-agent.log"

# Project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

wait_for_service() {
    local url=$1
    local name=$2
    local max_attempts=${3:-60}

    log_info "Waiting for $name to be ready..."
    for i in $(seq 1 $max_attempts); do
        if curl -sf "$url" > /dev/null 2>&1; then
            log_success "$name is ready!"
            return 0
        fi
        sleep 1
    done

    log_error "$name did not become ready in time"
    return 1
}

wait_for_postgres() {
    log_info "Waiting for PostgreSQL to be ready..."
    for i in $(seq 1 30); do
        if docker exec $POSTGRES_CONTAINER pg_isready -U $DB_USER -d $DB_NAME > /dev/null 2>&1; then
            log_success "PostgreSQL is ready!"
            return 0
        fi
        sleep 1
    done

    log_error "PostgreSQL did not become ready in time"
    return 1
}

# Command functions
cmd_start_postgres() {
    log_info "Starting PostgreSQL..."

    if docker ps -a --filter "name=$POSTGRES_CONTAINER" --format '{{.Names}}' | grep -q "$POSTGRES_CONTAINER"; then
        log_warning "PostgreSQL container already exists. Starting it..."
        docker start $POSTGRES_CONTAINER
    else
        docker run -d \
            --name $POSTGRES_CONTAINER \
            -e POSTGRES_DB=$DB_NAME \
            -e POSTGRES_USER=$DB_USER \
            -e POSTGRES_PASSWORD=$DB_PASSWORD \
            -p $POSTGRES_PORT:5432 \
            postgres:16-alpine
    fi

    wait_for_postgres
}

cmd_start_spicedb() {
    log_info "Starting SpiceDB..."

    # Get PostgreSQL container IP
    POSTGRES_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $POSTGRES_CONTAINER)
    CONN_STRING="postgres://$DB_USER:$DB_PASSWORD@${POSTGRES_IP}:5432/$DB_NAME?sslmode=disable"

    # Remove existing container if it exists
    if docker ps -a --filter "name=$SPICEDB_CONTAINER" --format '{{.Names}}' | grep -q "$SPICEDB_CONTAINER"; then
        log_warning "Removing existing SpiceDB container..."
        docker rm -f $SPICEDB_CONTAINER
    fi

    # Run SpiceDB migrations
    log_info "Running SpiceDB migrations..."
    docker run --rm \
        --network host \
        -e SPICEDB_DATASTORE_ENGINE=postgres \
        -e "SPICEDB_DATASTORE_CONN_URI=$CONN_STRING" \
        authzed/spicedb:v1.35.3 \
        migrate head

    # Start SpiceDB server
    docker run -d \
        --name $SPICEDB_CONTAINER \
        --network host \
        -e SPICEDB_DATASTORE_ENGINE=postgres \
        -e "SPICEDB_DATASTORE_CONN_URI=$CONN_STRING" \
        -e SPICEDB_GRPC_PRESHARED_KEY=$SPICEDB_KEY \
        authzed/spicedb:v1.35.3 \
        serve \
        --grpc-preshared-key $SPICEDB_KEY \
        --http-enabled \
        --http-addr :$SPICEDB_HTTP_PORT \
        --grpc-addr :$SPICEDB_GRPC_PORT

    wait_for_service "http://localhost:$SPICEDB_HTTP_PORT/healthz" "SpiceDB"
}

cmd_load_schema() {
    log_info "Loading SpiceDB schema..."

    docker run --rm \
        --network host \
        -v "$PROJECT_ROOT/spicedb/schema.zed:/schema.zed:ro" \
        authzed/zed:latest \
        schema write /schema.zed \
        --endpoint localhost:$SPICEDB_GRPC_PORT \
        --token $SPICEDB_KEY \
        --insecure

    log_success "SpiceDB schema loaded!"
}

cmd_start_control_plane() {
    log_info "Building and starting control-plane..."

    # Build control-plane
    log_info "Building control-plane..."
    cd "$PROJECT_ROOT/control-plane"
    swift build
    cd "$PROJECT_ROOT"

    # Run control-plane in background
    log_info "Starting control-plane..."

    export DATABASE_HOST=localhost
    export DATABASE_PORT=$POSTGRES_PORT
    export DATABASE_NAME=$DB_NAME
    export DATABASE_USERNAME=$DB_USER
    export DATABASE_PASSWORD=$DB_PASSWORD
    export SPICEDB_ENDPOINT=http://localhost:$SPICEDB_HTTP_PORT
    export SPICEDB_PRESHARED_KEY=$SPICEDB_KEY
    export WEBAUTHN_RELYING_PARTY_ID=localhost
    export WEBAUTHN_RELYING_PARTY_NAME=Strato
    export WEBAUTHN_RELYING_PARTY_ORIGIN=http://localhost:$CONTROL_PLANE_PORT

    nohup swift run --package-path "$PROJECT_ROOT/control-plane" > "$CONTROL_PLANE_LOG" 2>&1 &
    echo $! > "$CONTROL_PLANE_PID"

    wait_for_service "http://localhost:$CONTROL_PLANE_PORT/health/live" "Control Plane" 60
    log_success "Control Plane logs: $CONTROL_PLANE_LOG"
}

cmd_start_agent() {
    log_info "Building and starting agent..."

    # Create agent config
    cat > "$PROJECT_ROOT/config.toml" <<EOF
# Strato Agent Configuration
control_plane_url = "ws://localhost:$CONTROL_PLANE_PORT/agent/ws"
qemu_socket_dir = "/var/run/qemu"
log_level = "debug"
EOF

    # Build agent
    log_info "Building agent..."
    cd "$PROJECT_ROOT/agent"
    swift build
    cd "$PROJECT_ROOT"

    # Ensure QEMU socket directory exists
    sudo mkdir -p /var/run/qemu
    sudo chmod 777 /var/run/qemu

    # Run agent in background
    log_info "Starting agent..."
    nohup swift run --package-path "$PROJECT_ROOT/agent" StratoAgent \
        --config-file "$PROJECT_ROOT/config.toml" > "$AGENT_LOG" 2>&1 &
    echo $! > "$AGENT_PID"

    sleep 3
    log_success "Agent started!"
    log_success "Agent logs: $AGENT_LOG"
}

cmd_setup_test_data() {
    log_info "Setting up test user and organization..."

    # Create test user
    docker exec $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME <<EOF
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
EOF

    # Create organization
    docker exec $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME <<EOF
INSERT INTO organizations (id, name, description, created_at, updated_at)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'Default Organization',
    'Default organization for testing',
    NOW(),
    NOW()
)
ON CONFLICT (id) DO NOTHING;
EOF

    # Link user to organization
    docker exec $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME <<EOF
INSERT INTO user_organization (user_id, organization_id)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;
EOF

    # Set current organization
    docker exec $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME <<EOF
UPDATE users
SET current_organization_id = '00000000-0000-0000-0000-000000000001'
WHERE id = '00000000-0000-0000-0000-000000000001';
EOF

    # Create default project
    docker exec $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME <<EOF
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
EOF

    # Set up SpiceDB relationships
    log_info "Setting up authorization relationships..."

    # User is admin of organization
    curl -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $SPICEDB_KEY" \
        -d '{
            "operation": "OPERATION_CREATE",
            "resource": {
                "objectType": "organization",
                "objectId": "00000000-0000-0000-0000-000000000001"
            },
            "relation": "admin",
            "subject": {
                "object": {
                    "objectType": "user",
                    "objectId": "00000000-0000-0000-0000-000000000001"
                }
            }
        }' \
        "http://localhost:$SPICEDB_HTTP_PORT/v1/relationships/write" > /dev/null 2>&1

    # Project belongs to organization
    curl -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $SPICEDB_KEY" \
        -d '{
            "operation": "OPERATION_CREATE",
            "resource": {
                "objectType": "project",
                "objectId": "00000000-0000-0000-0000-000000000001"
            },
            "relation": "organization",
            "subject": {
                "object": {
                    "objectType": "organization",
                    "objectId": "00000000-0000-0000-0000-000000000001"
                }
            }
        }' \
        "http://localhost:$SPICEDB_HTTP_PORT/v1/relationships/write" > /dev/null 2>&1

    log_success "Test data created!"
}

cmd_status() {
    echo ""
    log_info "Service Status"
    echo ""

    # PostgreSQL
    printf "PostgreSQL:    "
    if docker ps --filter "name=$POSTGRES_CONTAINER" --format '{{.Status}}' | grep -q "Up"; then
        echo -e "${GREEN}✅ Running${NC}"
    else
        echo -e "${RED}❌ Stopped${NC}"
    fi

    # SpiceDB
    printf "SpiceDB:       "
    if docker ps --filter "name=$SPICEDB_CONTAINER" --format '{{.Status}}' | grep -q "Up"; then
        echo -e "${GREEN}✅ Running${NC}"
    else
        echo -e "${RED}❌ Stopped${NC}"
    fi

    # Control Plane
    printf "Control Plane: "
    if [ -f "$CONTROL_PLANE_PID" ] && kill -0 $(cat "$CONTROL_PLANE_PID") 2>/dev/null; then
        echo -e "${GREEN}✅ Running (PID: $(cat $CONTROL_PLANE_PID))${NC}"
    else
        echo -e "${RED}❌ Stopped${NC}"
    fi

    # Agent
    printf "Agent:         "
    if [ -f "$AGENT_PID" ] && kill -0 $(cat "$AGENT_PID") 2>/dev/null; then
        echo -e "${GREEN}✅ Running (PID: $(cat $AGENT_PID))${NC}"
    else
        echo -e "${RED}❌ Stopped${NC}"
    fi

    echo ""
}

cmd_logs() {
    local service=${1:-all}

    case $service in
        control-plane)
            if [ -f "$CONTROL_PLANE_LOG" ]; then
                tail -f "$CONTROL_PLANE_LOG"
            else
                log_error "Control Plane log not found"
            fi
            ;;
        agent)
            if [ -f "$AGENT_LOG" ]; then
                tail -f "$AGENT_LOG"
            else
                log_error "Agent log not found"
            fi
            ;;
        all|*)
            echo -e "${BLUE}=== Control Plane Logs (last 20 lines) ===${NC}"
            if [ -f "$CONTROL_PLANE_LOG" ]; then
                tail -20 "$CONTROL_PLANE_LOG"
            else
                echo "No logs found"
            fi
            echo ""
            echo -e "${BLUE}=== Agent Logs (last 20 lines) ===${NC}"
            if [ -f "$AGENT_LOG" ]; then
                tail -20 "$AGENT_LOG"
            else
                echo "No logs found"
            fi
            ;;
    esac
}

cmd_stop() {
    log_info "Stopping all services..."

    # Stop agent
    if [ -f "$AGENT_PID" ]; then
        if kill -0 $(cat "$AGENT_PID") 2>/dev/null; then
            log_info "Stopping agent (PID: $(cat $AGENT_PID))..."
            kill $(cat "$AGENT_PID")
        fi
        rm -f "$AGENT_PID"
    fi

    # Stop control-plane
    if [ -f "$CONTROL_PLANE_PID" ]; then
        if kill -0 $(cat "$CONTROL_PLANE_PID") 2>/dev/null; then
            log_info "Stopping control-plane (PID: $(cat $CONTROL_PLANE_PID))..."
            kill $(cat "$CONTROL_PLANE_PID")
        fi
        rm -f "$CONTROL_PLANE_PID"
    fi

    # Stop Docker containers
    log_info "Stopping Docker containers..."
    docker stop $SPICEDB_CONTAINER 2>/dev/null || true
    docker stop $POSTGRES_CONTAINER 2>/dev/null || true

    log_success "All services stopped!"
}

cmd_clean() {
    cmd_stop

    log_info "Cleaning up all resources..."

    # Remove Docker containers
    log_info "Removing Docker containers..."
    docker rm -f $SPICEDB_CONTAINER 2>/dev/null || true
    docker rm -f $POSTGRES_CONTAINER 2>/dev/null || true

    # Remove log files
    log_info "Removing log files..."
    rm -f "$CONTROL_PLANE_LOG" "$AGENT_LOG"

    log_success "Cleanup complete!"
}

cmd_dev() {
    log_info "Starting complete development environment..."
    echo ""

    cmd_start_postgres
    echo ""
    cmd_start_spicedb
    echo ""
    cmd_load_schema
    echo ""
    cmd_start_control_plane
    echo ""
    cmd_start_agent
    echo ""
    cmd_setup_test_data

    echo ""
    log_success "Development environment is fully running!"
    echo ""
    echo -e "${BLUE}📊 Service URLs:${NC}"
    echo "   • Control Plane:  http://localhost:$CONTROL_PLANE_PORT"
    echo "   • SpiceDB Admin:  http://localhost:$SPICEDB_HTTP_PORT"
    echo "   • PostgreSQL:     localhost:$POSTGRES_PORT"
    echo ""
    echo -e "${BLUE}📋 Useful Commands:${NC}"
    echo "   • View status:    $0 status"
    echo "   • View logs:      $0 logs [control-plane|agent|all]"
    echo "   • Stop services:  $0 stop"
    echo "   • Clean up:       $0 clean"
    echo ""
    echo -e "${BLUE}💡 Next Steps:${NC}"
    echo "   1. Open http://localhost:$CONTROL_PLANE_PORT in your browser"
    echo "   2. Register a new account or login"
    echo "   3. Complete onboarding to create an organization"
    echo "   4. Navigate to VMs and create a new VM"
    echo ""
}

# Main command dispatcher
case "${1:-}" in
    start-postgres)
        cmd_start_postgres
        ;;
    start-spicedb)
        cmd_start_spicedb
        ;;
    load-schema)
        cmd_load_schema
        ;;
    start-control-plane)
        cmd_start_control_plane
        ;;
    start-agent)
        cmd_start_agent
        ;;
    setup-test-data)
        cmd_setup_test_data
        ;;
    dev)
        cmd_dev
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs "${2:-all}"
        ;;
    stop)
        cmd_stop
        ;;
    clean)
        cmd_clean
        ;;
    *)
        echo "Strato Development Environment Setup"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  dev                  - Start complete development environment"
        echo "  start-postgres       - Start PostgreSQL database"
        echo "  start-spicedb        - Start SpiceDB authorization service"
        echo "  load-schema          - Load SpiceDB schema"
        echo "  start-control-plane  - Start control-plane service"
        echo "  start-agent          - Start agent service"
        echo "  setup-test-data      - Create test user and organization"
        echo "  status               - Show status of all services"
        echo "  logs [service]       - Show logs (control-plane, agent, or all)"
        echo "  stop                 - Stop all services"
        echo "  clean                - Stop services and remove all containers"
        echo ""
        echo "Quick start: $0 dev"
        exit 1
        ;;
esac
