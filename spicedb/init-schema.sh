#!/bin/bash

# Initialize SpiceDB schema for Strato
# This script loads the schema into SpiceDB via HTTP API

SPICEDB_ENDPOINT="${SPICEDB_ENDPOINT:-http://localhost:8080}"
SPICEDB_TOKEN="${SPICEDB_TOKEN:-strato-dev-key}"
SCHEMA_FILE="$(dirname "$0")/schema.zed"

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "Error: Schema file not found at $SCHEMA_FILE"
    exit 1
fi

echo "Loading SpiceDB schema from $SCHEMA_FILE..."

# Read schema content
SCHEMA_CONTENT=$(cat "$SCHEMA_FILE")

# Write schema to SpiceDB
curl -X POST "$SPICEDB_ENDPOINT/v1/schemas/write" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SPICEDB_TOKEN" \
    -d "{\"schema\": $(echo "$SCHEMA_CONTENT" | jq -Rs .)}" \
    --fail

if [ $? -eq 0 ]; then
    echo "Schema loaded successfully!"
else
    echo "Failed to load schema"
    exit 1
fi