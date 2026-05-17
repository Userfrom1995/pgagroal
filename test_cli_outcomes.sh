#!/bin/bash

# pgagroal CLI CONF SET test script
# This script runs pgagroal-cli conf set against a running server to verify outcomes.
# Run this from the build/src directory or set the PGAGROAL_BIN environment variable.

CLI=${PGAGROAL_BIN:-./pgagroal-cli}

if [ ! -f "$CLI" ]; then
    echo "ERROR: CLI binary not found at $CLI"
    echo "Please run this from the build/src directory or set PGAGROAL_BIN."
    exit 1
fi

echo "Using CLI: $CLI"
echo "Note: This script assumes a pgagroal server is already running."
echo "--------------------------------------------------"

# Function to run and describe
test_set() {
    local key=$1
    local value=$2
    local expected=$3
    local desc=$4

    echo "CASE: $desc"
    echo "CMD: $CLI conf set $key $value"
    echo "EXPECTED: $expected"
    $CLI conf set "$key" "$value"
    echo "--------------------------------------------------"
}

# 1. HOT CHANGES (Applied immediately to memory)
test_set "log_level" "info" "Success (Active)" "HOT change: Runtime logging verbosity"
test_set "log_connections" "on" "Success (Active)" "HOT change: Runtime logging flag"
test_set "blocking_timeout" "45s" "Success (Active)" "HOT change: Runtime timeout behavior"

# 2. SERVICE CHANGES (Restart Required - saved to disk but not memory)
test_set "port" "2345" "Restart Required" "SERVICE change: Main port rebind"
test_set "metrics" "9900" "Restart Required" "SERVICE change: Metrics endpoint"
test_set "unix_socket_dir" "/tmp" "Restart Required" "SERVICE change: UDS path"

# 3. FULL RESTART CHANGES (Critical architecture/resource changes)
test_set "max_connections" "100" "Restart Required" "FULL change: Resource sizing"
test_set "pipeline" "performance" "Restart Required" "FULL change: Core processing model"
test_set "ev_backend" "epoll" "Restart Required" "FULL change: Event architecture"

# 4. CONTEXTUAL CHANGES (Server/Limit/HBA)
# Note: These assume section/context exists in your current running config
test_set "server.primary.host" "127.0.0.1" "Restart Required" "Contextual: Server endpoint change"
test_set "limit.postgres.max_size" "15" "Restart Required" "Contextual: Limit policy update"
test_set "hba.admin.type" "host" "Success (Active)" "Contextual: HBA rule update (HOT supported)"

# 5. FAILURE CASES
test_set "non_existent_key" "value" "Failure (Invalid key)" "Error: Unknown parameter"
test_set "port" "-1" "Failure (Invalid value)" "Error: Out of range value validation"

echo "Tests finished."
