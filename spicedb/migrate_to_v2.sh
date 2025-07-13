#!/bin/bash

# SpiceDB Schema Migration Script
# Migrates from v1 schema (flat organizations) to v2 schema (hierarchical)

set -e

echo "SpiceDB Schema Migration: v1 to v2"
echo "================================="

# Check if SpiceDB is accessible
if ! command -v zed &> /dev/null; then
    echo "Error: 'zed' command not found. Please install SpiceDB CLI."
    exit 1
fi

# Configuration
SPICEDB_ENDPOINT="${SPICEDB_ENDPOINT:-localhost:50051}"
SPICEDB_TOKEN="${SPICEDB_TOKEN:-strato-dev-token}"

echo "Using SpiceDB endpoint: $SPICEDB_ENDPOINT"

# Step 1: Apply the new schema
echo ""
echo "Step 1: Applying new schema..."
zed schema write --endpoint="$SPICEDB_ENDPOINT" --token="$SPICEDB_TOKEN" schema_v2.zed

if [ $? -eq 0 ]; then
    echo "✓ New schema applied successfully"
else
    echo "✗ Failed to apply new schema"
    exit 1
fi

# Step 2: Create migration relationships script
echo ""
echo "Step 2: Creating relationship migration script..."

cat > migrate_relationships.zed << 'EOF'
// This script should be customized based on your actual data
// It shows the pattern for migrating relationships

// For each VM, we need to:
// 1. Find its organization (from existing relationship)
// 2. Create a default project in that organization
// 3. Create a default environment in that project
// 4. Update the VM relationship to point to the project instead of organization

// Example migration for a single VM:
// Old: vm:vm-uuid#organization@organization:org-uuid
// New: vm:vm-uuid#project@project:default-project-uuid
//      vm:vm-uuid#environment@environment:development

// The actual migration would need to be done programmatically
// by querying existing relationships and creating new ones
EOF

echo "✓ Migration script template created"

# Step 3: Provide migration instructions
echo ""
echo "Step 3: Migration Instructions"
echo "=============================="
echo ""
echo "To complete the migration, you need to:"
echo ""
echo "1. Run a script to create default projects for each organization"
echo "2. Update all VM relationships to point to projects instead of organizations"
echo "3. Create environment relationships for all VMs (default: development)"
echo "4. Update your application code to use the new permission model"
echo ""
echo "Example commands for manual migration:"
echo ""
echo "# List all current VM->Organization relationships"
echo "zed relationship read --endpoint=\"$SPICEDB_ENDPOINT\" --token=\"$SPICEDB_TOKEN\" 'vm:*#organization@organization:*'"
echo ""
echo "# Create a default project for an organization"
echo "zed relationship create --endpoint=\"$SPICEDB_ENDPOINT\" --token=\"$SPICEDB_TOKEN\" 'project:default-proj-uuid#parent@organization:org-uuid'"
echo ""
echo "# Update a VM to use the new project relationship"
echo "zed relationship create --endpoint=\"$SPICEDB_ENDPOINT\" --token=\"$SPICEDB_TOKEN\" 'vm:vm-uuid#project@project:default-proj-uuid'"
echo ""
echo "# Create environment relationship"
echo "zed relationship create --endpoint=\"$SPICEDB_ENDPOINT\" --token=\"$SPICEDB_TOKEN\" 'environment:development#project@project:default-proj-uuid'"
echo "zed relationship create --endpoint=\"$SPICEDB_ENDPOINT\" --token=\"$SPICEDB_TOKEN\" 'vm:vm-uuid#environment@environment:development'"
echo ""
echo "WARNING: This is a breaking change. Ensure you have backups before proceeding."
echo "WARNING: Update your application code to use the new schema before switching."

# Make the script executable
chmod +x migrate_relationships.zed