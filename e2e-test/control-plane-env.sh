#!/bin/bash
# Control Plane Environment Configuration
# Source this file before running the control plane: source control-plane-env.sh

# Database Configuration
export DATABASE_HOST=localhost
export DATABASE_PORT=5432
export DATABASE_USERNAME=vapor_username
export DATABASE_PASSWORD=vapor_password
export DATABASE_NAME=vapor_database

# WebAuthn Configuration (for web UI authentication)
export WEBAUTHN_RELYING_PARTY_ID=localhost
export WEBAUTHN_RELYING_PARTY_NAME=Strato
export WEBAUTHN_RELYING_PARTY_ORIGIN=http://localhost:8080

# Scheduler Configuration
export SCHEDULING_STRATEGY=least_loaded

# SpiceDB Configuration (Required!)
export SPICEDB_ENDPOINT=localhost:50051
export SPICEDB_GRPC_ENDPOINT=localhost:50051
export SPICEDB_HTTP_ENDPOINT=http://localhost:8081
export SPICEDB_PRESHARED_KEY=strato-dev-key

echo "✅ Control Plane environment variables configured"
echo "   Database: ${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}"
echo "   WebAuthn Origin: ${WEBAUTHN_RELYING_PARTY_ORIGIN}"
echo "   Scheduling Strategy: ${SCHEDULING_STRATEGY}"
