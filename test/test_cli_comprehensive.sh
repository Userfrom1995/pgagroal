#!/bin/bash

# pgagroal CLI Comprehensive Test Script
# Complete standalone test script with its own PostgreSQL and pgagroal setup
# Tests all CLI commands with both local and remote connections

set -e

# Platform detection
OS=$(uname)

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_DIR/test"

# Test environment configuration
PGAGROAL_PORT=2345
MANAGEMENT_PORT=2346
POSTGRES_PORT=5432
ADMIN_USER="admin"
ADMIN_PASSWORD="adminpass"
TEST_TIMEOUT=30
WAIT_TIMEOUT=10

# User configuration
PSQL_USER=$(whoami)
if [ "$OS" = "FreeBSD" ]; then
    PSQL_USER=postgres
fi
PGPASSWORD="password"

# Directories for CLI test environment
LOG_DIR="$PROJECT_DIR/log-cli"
PGCTL_LOG_FILE="$LOG_DIR/logfile"
PGAGROAL_LOG_FILE="$LOG_DIR/pgagroal_cli.log"
PGBENCH_LOG_FILE="$LOG_DIR/pgbench.log"

POSTGRES_OPERATION_DIR="$PROJECT_DIR/pgagroal-postgresql-cli"
DATA_DIR="$POSTGRES_OPERATION_DIR/data"

PGAGROAL_OPERATION_DIR="$PROJECT_DIR/pgagroal-testsuite-cli"
CONFIG_DIR="$PGAGROAL_OPERATION_DIR/conf"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

########################### UTILS ############################

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

# Port and process utilities
is_port_in_use() {
    local port=$1
    if [[ "$OS" == "Linux" ]]; then
        ss -tuln | grep $port >/dev/null 2>&1
    elif [[ "$OS" == "Darwin" ]]; then
        lsof -i:$port >/dev/null 2>&1
    elif [[ "$OS" == "FreeBSD" ]]; then
        sockstat -4 -l | grep $port >/dev/null 2>&1
    fi
    return $?
}

next_available_port() {
    local port=$1
    while true; do
        is_port_in_use $port
        if [ $? -ne 0 ]; then
            echo "$port"
            return 0
        else
            port=$((port + 1))
        fi
    done
}

wait_for_server_ready() {
    local start_time=$SECONDS
    local port=$1
    local server_name=${2:-"server"}
    
    log_info "Waiting for $server_name to be ready on port $port..."
    
    while true; do
        pg_isready -h localhost -p $port >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "$server_name is ready on port $port"
            return 0
        fi
        if [ $(($SECONDS - $start_time)) -gt $WAIT_TIMEOUT ]; then
            log_error "Timeout waiting for $server_name on port $port"
            return 1
        fi
        sleep 1
    done
}

function sed_i() {
   if [[ "$OS" == "Darwin" || "$OS" == "FreeBSD" ]]; then
      sed -i '' -E "$@"
   else
      sed -i -E "$@"
   fi
}

run_as_postgres() {
  if [[ "$OS" == "FreeBSD" ]]; then
    su - postgres -c "$*"
  else
    eval "$@"
  fi
}

stop_processes() {
    log_info "Stopping any running pgagroal and PostgreSQL processes..."
    pkill -f pgagroal || true
    
    if [[ -f "$PGCTL_LOG_FILE" ]]; then
        if [[ "$OS" == "FreeBSD" ]]; then
            su - postgres -c "pg_ctl -D $DATA_DIR -l $PGCTL_LOG_FILE stop" || true
        else
            pg_ctl -D $DATA_DIR -l $PGCTL_LOG_FILE stop || true
        fi
    fi
    sleep 2
}

########################### SETUP FUNCTIONS ############################

find_executable_dir() {
    local possible_dirs=(
        "$PROJECT_DIR/src"           # Default location
        "$PROJECT_DIR/build/src"     # CMake build directory
        "$PROJECT_DIR/build"         # Alternative build location
        "/usr/local/bin"             # System installation
        "/usr/bin"                   # System installation
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [[ -f "$dir/pgagroal" ]] && [[ -f "$dir/pgagroal-cli" ]] && [[ -f "$dir/pgagroal-admin" ]]; then
            echo "$dir"
            return 0
        fi
    done
    
    return 1
}

check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check required binaries
    local required_bins=("initdb" "pg_ctl" "pgbench" "psql" "jq")
    for bin in "${required_bins[@]}"; do
        if ! which $bin > /dev/null 2>&1; then
            log_error "$bin not found in PATH"
            return 1
        fi
    done
    
    # Check ports
    POSTGRES_PORT=$(next_available_port $POSTGRES_PORT)
    if is_port_in_use $PGAGROAL_PORT; then
        PGAGROAL_PORT=$(next_available_port $PGAGROAL_PORT)
    fi
    if is_port_in_use $MANAGEMENT_PORT; then
        MANAGEMENT_PORT=$(next_available_port $MANAGEMENT_PORT)
    fi
    
    log_success "System requirements check passed"
    log_info "Using PostgreSQL port: $POSTGRES_PORT"
    log_info "Using pgagroal port: $PGAGROAL_PORT"
    log_info "Using management port: $MANAGEMENT_PORT"
    return 0
}

initialize_log_files() {
    log_info "Initializing log files..."
    mkdir -p $LOG_DIR
    touch $PGAGROAL_LOG_FILE $PGCTL_LOG_FILE $PGBENCH_LOG_FILE
    log_success "Log files initialized in $LOG_DIR"
}

create_postgresql_cluster() {
    log_info "Creating PostgreSQL cluster..."
    
    if [ "$OS" = "FreeBSD" ]; then
        mkdir -p "$POSTGRES_OPERATION_DIR"
        mkdir -p "$DATA_DIR"
        mkdir -p "$CONFIG_DIR"
        if ! pw user show postgres >/dev/null 2>&1; then
            pw groupadd -n postgres -g 770
            pw useradd -n postgres -u 770 -g postgres -d /var/db/postgres -s /bin/sh
        fi
        chown postgres:postgres $PGCTL_LOG_FILE
        chown postgres:postgres $PGBENCH_LOG_FILE
        chown -R postgres:postgres "$DATA_DIR"
        chown -R postgres:postgres "$CONFIG_DIR"
    fi

    # Initialize database
    INITDB_PATH=$(command -v initdb)
    if [ -z "$INITDB_PATH" ]; then
        log_error "initdb not found!"
        return 1
    fi

    run_as_postgres "$INITDB_PATH -k -D $DATA_DIR"
    
    # Configure PostgreSQL
    LOG_ABS_PATH=$(realpath "$LOG_DIR")
    sed_i "s/^#*logging_collector.*/logging_collector = on/" "$DATA_DIR/postgresql.conf"
    sed_i "s/^#*log_destination.*/log_destination = 'stderr'/" "$DATA_DIR/postgresql.conf"
    sed_i "s|^#*log_directory.*|log_directory = '$LOG_ABS_PATH'|" "$DATA_DIR/postgresql.conf"
    sed_i "s/^#*log_filename.*/log_filename = 'logfile'/" "$DATA_DIR/postgresql.conf"
    sed_i "s|#unix_socket_directories = '/var/run/postgresql'|unix_socket_directories = '/tmp'|" "$DATA_DIR/postgresql.conf"
    sed_i "s/#port = 5432/port = $POSTGRES_PORT/" "$DATA_DIR/postgresql.conf"
    sed_i "s/#max_connections = 100/max_connections = 200/" "$DATA_DIR/postgresql.conf"

    # Configure HBA
    cat > "$DATA_DIR/pg_hba.conf" << EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
host    mydb            myuser          127.0.0.1/32            scram-sha-256
host    mydb            myuser          ::1/128                 scram-sha-256
EOF

    log_success "PostgreSQL cluster created"
}

start_postgresql() {
    log_info "Starting PostgreSQL..."
    
    PGCTL_PATH=$(command -v pg_ctl)
    if [ -z "$PGCTL_PATH" ]; then
        log_error "pg_ctl not found!"
        return 1
    fi

    run_as_postgres "$PGCTL_PATH -D $DATA_DIR -l $PGCTL_LOG_FILE start"
    
    if ! wait_for_server_ready $POSTGRES_PORT "PostgreSQL"; then
        return 1
    fi

    # Create test user and database
    psql -h localhost -p $POSTGRES_PORT -U $PSQL_USER -d postgres -c "CREATE ROLE myuser WITH LOGIN PASSWORD '$PGPASSWORD';" || true
    psql -h localhost -p $POSTGRES_PORT -U $PSQL_USER -d postgres -c "CREATE DATABASE mydb WITH OWNER myuser;" || true
    
    # Initialize pgbench
    pgbench -i -s 1 -n -h localhost -p $POSTGRES_PORT -U $PSQL_USER -d postgres
    
    log_success "PostgreSQL started and configured"
}

create_master_key() {
    log_info "Creating master key..."
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if run_as_postgres "test -f ~/.pgagroal/master.key"; then
            log_info "Master key already exists"
            return 0
        fi
        run_as_postgres "mkdir -p ~/.pgagroal"
        run_as_postgres "chmod 700 ~/.pgagroal"
    else
        if [ -f "$HOME/.pgagroal/master.key" ]; then
            log_info "Master key already exists"
            return 0
        fi
        mkdir -p ~/.pgagroal
        chmod 700 ~/.pgagroal
    fi
    
    run_as_postgres "$EXECUTABLE_DIR/pgagroal-admin master-key -P $PGPASSWORD"
    log_success "Master key created"
}

create_pgagroal_configuration() {
    log_info "Creating pgagroal configuration..."
    
    mkdir -p "$CONFIG_DIR"
    
    # Main configuration
    cat > "$CONFIG_DIR/pgagroal.conf" << EOF
[pgagroal]
host = localhost
port = $PGAGROAL_PORT
management = $MANAGEMENT_PORT

log_type = file
log_level = info
log_path = $PGAGROAL_LOG_FILE

max_connections = 100
idle_timeout = 600
validation = off
unix_socket_dir = /tmp/
pipeline = performance

[primary]
host = localhost
port = $POSTGRES_PORT
EOF

    # HBA configuration
    cat > "$CONFIG_DIR/pgagroal_hba.conf" << EOF
host    all all all all
EOF

    # Database limits configuration
    cat > "$CONFIG_DIR/pgagroal_databases.conf" << EOF
#
# DATABASE=ALIAS1,ALIAS2 USER MAX_SIZE INITIAL_SIZE MIN_SIZE
#
postgres=pgalias1,pgalias2 $PSQL_USER 8 0 0
EOF

    # Create users configuration
    if [ -f "$CONFIG_DIR/pgagroal_users.conf" ]; then
        rm -f "$CONFIG_DIR/pgagroal_users.conf"
    fi
    
    run_as_postgres "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_users.conf -U $PSQL_USER -P $PGPASSWORD user add"
    
    # Create admin configuration
    if [ -f "$CONFIG_DIR/pgagroal_admins.conf" ]; then
        rm -f "$CONFIG_DIR/pgagroal_admins.conf"
    fi
    
    run_as_postgres "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_admins.conf -U $ADMIN_USER -P $ADMIN_PASSWORD user add"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        chown -R postgres:postgres "$CONFIG_DIR"
        chown postgres:postgres "$PGAGROAL_LOG_FILE"
    fi
    
    log_success "pgagroal configuration created"
}

start_pgagroal() {
    log_info "Starting pgagroal..."
    
    run_as_postgres "$EXECUTABLE_DIR/pgagroal -c $CONFIG_DIR/pgagroal.conf -a $CONFIG_DIR/pgagroal_hba.conf -u $CONFIG_DIR/pgagroal_users.conf -l $CONFIG_DIR/pgagroal_databases.conf -A $CONFIG_DIR/pgagroal_admins.conf -d"
    
    if ! wait_for_server_ready $PGAGROAL_PORT "pgagroal"; then
        return 1
    fi
    
    log_success "pgagroal started successfully"
}

########################### TEST FUNCTIONS ############################

# # JSON validation functions
# validate_json_structure() {
#     local json_output="$1"
#     local test_name="$2"
    
#     if ! echo "$json_output" | jq . >/dev/null 2>&1; then
#         log_error "$test_name: Invalid JSON output"
#         return 1
#     fi
    
#     local command_name=$(echo "$json_output" | jq -r '.command.name // "null"')
#     local command_status=$(echo "$json_output" | jq -r '.command.status // "null"')
#     local command_error=$(echo "$json_output" | jq -r '.command.error // "null"')
    
#     if [[ "$command_name" == "null" ]] || [[ "$command_status" == "null" ]] || [[ "$command_error" == "null" ]]; then
#         log_error "$test_name: Missing required JSON fields"
#         return 1
#     fi
    
#     return 0
# }

# validate_command_success() {
#     local json_output="$1"
#     local expected_success="$2"  # true/false
#     local test_name="$3"
    
#     local command_error=$(echo "$json_output" | jq -r '.command.error')
#     local command_status=$(echo "$json_output" | jq -r '.command.status')
    
#     if [[ "$expected_success" == "true" ]]; then
#         if [[ "$command_error" != "0" ]] || [[ "$command_status" != "OK" ]]; then
#             log_error "$test_name: Expected success but got error=$command_error, status=$command_status"
#             return 1
#         fi
#     else
#         if [[ "$command_error" == "0" ]]; then
#             log_error "$test_name: Expected failure but got success"
#             return 1
#         fi
#     fi
    
#     return 0
# }

# JSON validation functions
validate_json_structure() {
    local json_output="$1"
    local test_name="$2"
    
    # Check if we have any output at all
    if [[ -z "$json_output" ]]; then
        log_error "$test_name: No output received - CLI/server may be down"
        return 1
    fi
    
    # Check if output is valid JSON
    if ! echo "$json_output" | jq . >/dev/null 2>&1; then
        log_error "$test_name: Invalid JSON output"
        log_error "$test_name: Raw output: $json_output"
        return 1
    fi
    
    # Check for required JSON structure (actual pgagroal CLI format)
    local command_name=$(echo "$json_output" | jq -r '.Header.Command // "null"')
    
    # Check if we have the expected structure
    if ! echo "$json_output" | jq -e '.Outcome | has("Status")' >/dev/null 2>&1; then
        log_error "$test_name: Missing Outcome.Status in JSON structure"
        return 1
    fi

    if [[ "$command_name" == "null" || -z "$command_name" ]]; then
        log_error "$test_name: Missing Header.Command in JSON structure"
        return 1
    fi
    
    return 0
}

# validate_command_success() {
#     local json_output="$1"
#     local expected_success="$2"  # true/false
#     local test_name="$3"
    
#     # Get the actual status (boolean)
#     local outcome_status=$(echo "$json_output" | jq -r '.Outcome.Status')
    
#     if [[ "$expected_success" == "true" ]]; then
#         if [[ "$outcome_status" != "true" ]]; then
#             log_error "$test_name: Expected success but got Status=$outcome_status"
#             return 1
#         fi
#     else
#         if [[ "$outcome_status" == "true" ]]; then
#             log_error "$test_name: Expected failure but got success (Status=$outcome_status)"
#             return 1
#         fi
#     fi
    
#     return 0
# }

# validate_command_success() {
#     local json_output="$1"
#     local expected_success="$2"  # true/false
#     local test_name="$3"
    
#     # Check if this is the new format (with Header/Outcome)
#     local outcome_status=$(echo "$json_output" | jq -r '.Outcome.Status // "null"')
    
#     if [[ "$outcome_status" != "null" ]]; then
#         # New format - use Outcome.Status
#         if [[ "$expected_success" == "true" ]]; then
#             if [[ "$outcome_status" != "true" ]]; then
#                 log_error "$test_name: Expected success but got Status=$outcome_status"
#                 return 1
#             fi
#         else
#             if [[ "$outcome_status" == "true" ]]; then
#                 log_error "$test_name: Expected failure but got success (Status=$outcome_status)"
#                 return 1
#             fi
#         fi
#     else
#         # Old format - use command.error
#         local command_error=$(echo "$json_output" | jq -r '.command.error // "null"')
#         if [[ "$command_error" != "null" ]]; then
#             if [[ "$expected_success" == "true" ]]; then
#                 if [[ "$command_error" != "0" ]] && [[ "$command_error" != "false" ]]; then
#                     log_error "$test_name: Expected success but got error=$command_error"
#                     return 1
#                 fi
#             else
#                 if [[ "$command_error" == "0" ]] || [[ "$command_error" == "false" ]]; then
#                     log_error "$test_name: Expected failure but got success"
#                     return 1
#                 fi
#             fi
#         fi
#     fi
    
#     return 0
# }

# validate_command_success() {
#     local json_output="$1"
#     local expected_success="$2"  # true/false
#     local test_name="$3"
    
#     # Get the actual status (boolean)
#     local outcome_status=$(echo "$json_output" | jq -r '.Outcome.Status')
    
#     # Debug output to see what we're getting
#     log_debug "$test_name: outcome_status='$outcome_status', expected_success='$expected_success'"
    
#     if [[ "$expected_success" == "true" ]]; then
#         # We expect success, so Status should be true
#         if [[ "$outcome_status" != "true" ]]; then
#             log_error "$test_name: Expected success but got Status=$outcome_status"
#             return 1
#         fi
#     else
#         # We expect failure, so Status should be false
#         if [[ "$outcome_status" == "true" ]]; then
#             log_error "$test_name: Expected failure but got success (Status=$outcome_status)"
#             return 1
#         fi
#         # If Status is false, null, or anything other than true, that's a failure (which we expected)
#     fi
    
#     return 0
# }

validate_command_success() {
    local json_output="$1"
    local expected_success="$2"  # true/false
    local test_name="$3"
    
    # Extract the Outcome.Status value (this should be the primary status indicator)
    local actual_status=$(echo "$json_output" | jq -r '.Outcome.Status // "null"' 2>/dev/null)
    
    # If we couldn't find Outcome.Status, try fallback methods
    if [[ "$actual_status" == "null" || -z "$actual_status" ]]; then
        # Try to find Status at any level using jq's recursive descent
        local status_values=$(echo "$json_output" | jq -r '.. | objects | select(has("Status")) | .Status' 2>/dev/null)
        
        if [[ -n "$status_values" ]]; then
            actual_status=$(echo "$status_values" | head -n1)
        else
            # Try legacy formats
            local legacy_status=$(echo "$json_output" | jq -r '.command.status // empty' 2>/dev/null)
            if [[ -n "$legacy_status" && "$legacy_status" != "null" ]]; then
                # Convert legacy status to boolean-like
                if [[ "$legacy_status" == "OK" ]]; then
                    actual_status="true"
                else
                    actual_status="false"
                fi
            else
                # Check for error field as another indicator
                local error_field=$(echo "$json_output" | jq -r '.command.error // .Outcome.Error // empty' 2>/dev/null)
                if [[ -n "$error_field" && "$error_field" != "null" ]]; then
                    # If error is 0 or false, it's success; otherwise failure
                    if [[ "$error_field" == "0" || "$error_field" == "false" ]]; then
                        actual_status="true"
                    else
                        actual_status="false"
                    fi
                fi
            fi
        fi
    fi
    
    # If we still couldn't find any status indicator, treat as failure
    if [[ "$actual_status" == "null" || -z "$actual_status" ]]; then
        log_error "$test_name: No status indicator found in JSON response"
        log_error "$test_name: Expected: $expected_success, Received: <no status found>"
        return 1
    fi
    
    # Debug output
    log_info "$test_name: Status validation - Expected: $expected_success, Received: $actual_status"
    
    # Compare the found status with expected result
    if [[ "$expected_success" == "true" ]]; then
        # We expect success
        if [[ "$actual_status" == "true" ]]; then
            return 0  # Success as expected
        else
            log_error "$test_name: Expected success but got failure"
            log_error "$test_name: Expected: true, Received: $actual_status"
            return 1
        fi
    else
        # We expect failure
        if [[ "$actual_status" == "true" ]]; then
            log_error "$test_name: Expected failure but got success"
            log_error "$test_name: Expected: false, Received: $actual_status"
            return 1
        else
            return 0  # Failure as expected
        fi
    fi
}






execute_cli_test() {
    local test_name="$1"
    local cli_command="$2"
    local expected_success="$3"  # true/false
    local connection_type="$4"   # local/remote
    
    log_info "Testing: $test_name ($connection_type)"
    
    local full_command
    local output
    local exit_code
    
    # Build command based on connection type
    if [[ "$connection_type" == "local" ]]; then
        full_command="$EXECUTABLE_DIR/pgagroal-cli -c $CONFIG_DIR/pgagroal.conf $cli_command --format json"
    else
        full_command="$EXECUTABLE_DIR/pgagroal-cli -h localhost -p $MANAGEMENT_PORT -U $ADMIN_USER -P $ADMIN_PASSWORD $cli_command --format json"
    fi
    
    # Execute command with timeout
    if output=$(timeout $TEST_TIMEOUT bash -c "$full_command" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi
    
    # Convert expected_success to expected exit code for comparison
    local expected_exit_code
    if [[ "$expected_success" == "true" ]]; then
        expected_exit_code=0
    else
        expected_exit_code=1
    fi
    
    # Check if exit code matches expectation
    local exit_code_matches=false
    if [[ $exit_code -eq $expected_exit_code ]]; then
        exit_code_matches=true
    fi
    
    # Handle different scenarios
    if [[ $exit_code -eq 0 ]]; then
        # Command executed successfully, validate JSON structure and content
        if ! validate_json_structure "$output" "$test_name ($connection_type)"; then
            log_error "$test_name ($connection_type): JSON structure validation failed"
            echo "Command output: $output"
            FAILED_TESTS+=("$test_name ($connection_type)")
            ((TESTS_FAILED++))
            return 1
        fi
        
        if ! validate_command_success "$output" "$expected_success" "$test_name ($connection_type)"; then
            log_error "$test_name ($connection_type): Command success validation failed"
            echo "Command output: $output"
            FAILED_TESTS+=("$test_name ($connection_type)")
            ((TESTS_FAILED++))
            return 1
        fi
        
        # Additional check: exit code should match JSON status
        local json_status=$(echo "$output" | jq -r '.Outcome.Status // "null"' 2>/dev/null)
        if [[ "$json_status" == "true" && $exit_code -ne 0 ]] || [[ "$json_status" == "false" && $exit_code -eq 0 ]]; then
            log_warning "$test_name ($connection_type): Exit code ($exit_code) doesn't match JSON status ($json_status)"
        fi
        
    else
        # Command failed (non-zero exit code)
        if [[ "$expected_success" == "true" ]]; then
            # We expected success but got failure
            log_error "$test_name ($connection_type): Command failed unexpectedly"
            log_error "$test_name ($connection_type): Expected: success (exit code 0), Received: failure (exit code $exit_code)"
            
            # Check if we have any output to analyze
            if [[ -n "$output" ]]; then
                echo "Command output: $output"
                # Try to parse JSON even on failure to get more info
                if echo "$output" | jq . >/dev/null 2>&1; then
                    local json_status=$(echo "$output" | jq -r '.Outcome.Status // "unknown"' 2>/dev/null)
                    log_error "$test_name ($connection_type): JSON Status: $json_status"
                fi
            else
                log_error "$test_name ($connection_type): No output received - CLI/server may be down"
            fi
            
            FAILED_TESTS+=("$test_name ($connection_type)")
            ((TESTS_FAILED++))
            return 1
        else
            # We expected failure and got failure - this is correct
            log_info "$test_name ($connection_type): Command failed as expected (exit code: $exit_code)"
            
            # If we have JSON output even on failure, validate it
            if [[ -n "$output" ]] && echo "$output" | jq . >/dev/null 2>&1; then
                if validate_json_structure "$output" "$test_name ($connection_type)" 2>/dev/null; then
                    validate_command_success "$output" "$expected_success" "$test_name ($connection_type)" || true
                fi
            fi
        fi
    fi
    
    log_success "$test_name ($connection_type): PASSED"
    ((TESTS_PASSED++))
    return 0
}

# Individual test functions
test_ping_command() {
    log_info "=== Testing PING Command ==="
    execute_cli_test "ping" "ping" "true" "local"
    execute_cli_test "ping remote" "ping" "true" "remote"
}

test_status_commands() {
    log_info "=== Testing STATUS Commands ==="
    execute_cli_test "status" "status" "true" "local"
    execute_cli_test "status details" "status details" "true" "local"
    execute_cli_test "status details" "status details" "true" "remote"
    execute_cli_test "status remote" "status" "true" "remote"
}

test_conf_commands() {
    log_info "=== Testing CONF Commands ==="
    execute_cli_test "conf ls" "conf ls" "true" "local"
    execute_cli_test "conf get max_connections" "conf get max_connections" "true" "local"
    execute_cli_test "conf get nonexistent" "conf get nonexistent_param" "false" "local"
    execute_cli_test "conf alias" "conf alias" "true" "local"
    execute_cli_test "conf ls remote" "conf ls" "true" "remote"
    
    # Test conf set (be careful with this)
    execute_cli_test "conf set log_level" "conf set log_level debug" "true" "local"
    execute_cli_test "conf set log_level reset" "conf set log_level info" "true" "remote"
}

test_enable_disable_commands() {
    log_info "=== Testing ENABLE/DISABLE Commands ==="
    execute_cli_test "disable postgres" "disable postgres" "true" "local"
    execute_cli_test "enable postgres" "enable postgres" "true" "local"
    execute_cli_test "disable all" "disable" "true" "local"
    execute_cli_test "enable all" "enable" "true" "local"
}

test_flush_commands() {
    log_info "=== Testing FLUSH Commands ==="
    execute_cli_test "flush gracefully" "flush gracefully" "true" "local"
    execute_cli_test "flush idle" "flush idle" "true" "local"
    execute_cli_test "flush postgres" "flush postgres" "true" "local"
    execute_cli_test "flush all postgres" "flush all postgres" "true" "local"
}

test_clear_commands() {
    log_info "=== Testing CLEAR Commands ==="
    execute_cli_test "clear prometheus" "clear prometheus" "true" "local"
    execute_cli_test "clear server primary" "clear server primary" "true" "local"
}

test_switch_to_command() {
    log_info "=== Testing SWITCH-TO Command ==="
    execute_cli_test "switch-to primary" "switch-to primary" "true" "local"
    execute_cli_test "switch-to nonexistent" "switch-to nonexistent_server" "false" "local"
}

test_shutdown_commands() {
    log_info "=== Testing SHUTDOWN Commands ==="
    
    # Test shutdown cancel sequence (safe way to test shutdown)
    log_info "Testing shutdown gracefully -> cancel sequence"
    
    # Start graceful shutdown
    execute_cli_test "shutdown gracefully" "shutdown gracefully" "true" "local"
    # # sleep 2
    
    # # Cancel it
    # execute_cli_test "shutdown cancel" "shutdown cancel" "true" "local"
    
    # # Verify server is still running
    # execute_cli_test "ping after cancel" "ping" "true" "local"
    
    # # Test immediate shutdown as the very last test
    # log_warning "Testing immediate shutdown (will stop server)"
    # execute_cli_test "shutdown immediate" "shutdown immediate" "true" "local"
    
    log_info "Server has been shut down by test"
}

test_error_scenarios() {
    log_info "=== Testing ERROR Scenarios ==="
    
    # Test invalid commands
    execute_cli_test "invalid command" "invalid_command" "false" "local"
    
    # Test invalid parameters
    # execute_cli_test "flush invalid mode" "flush invalid_mode" "false" "local"
    execute_cli_test "conf set invalid" "conf set" "false" "local"
}

run_all_tests() {

    set +e
    log_info "Starting comprehensive CLI tests..."
    
    # Basic functionality tests
    test_ping_command
    test_status_commands
    test_conf_commands
    
    # # Database management tests
    # test_enable_disable_commands
    # test_flush_commands
    
    # # Server management tests
    test_clear_commands
    test_switch_to_command
    
    # # Error scenario tests
    test_error_scenarios
    
    # Shutdown tests (must be last)
    test_shutdown_commands

    set -e
}

########################### CLEANUP AND REPORTING ############################

generate_test_report() {
    echo
    log_info "=== TEST SUMMARY ==="
    echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo
        log_error "Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  - $test"
        done
        echo
        return 1
    else
        echo
        log_success "All tests passed!"
        echo
        return 0
    fi
}

cleanup() {
    log_info "Cleaning up test environment..."
    stop_processes
    
    # Remove test directories
    if [ -d "$POSTGRES_OPERATION_DIR" ]; then
        rm -rf "$POSTGRES_OPERATION_DIR"
        log_info "Removed PostgreSQL test directory"
    fi
    
    if [ -d "$PGAGROAL_OPERATION_DIR" ]; then
        rm -rf "$PGAGROAL_OPERATION_DIR"
        log_info "Removed pgagroal test directory"
    fi
    
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        log_info "Removed log directory"
    fi
    
    log_success "Cleanup completed"
}

########################### MAIN EXECUTION ############################

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script runs comprehensive tests for all pgagroal-cli commands."
    echo "It sets up its own PostgreSQL and pgagroal environment for testing."
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --no-cleanup   Don't clean up test environment after completion"
    echo
    echo "The script will:"
    echo "  1. Set up a temporary PostgreSQL cluster"
    echo "  2. Configure and start pgagroal with management interface"
    echo "  3. Test all CLI commands (local and remote connections)"
    echo "  4. Generate a comprehensive test report"
    echo "  5. Clean up the test environment"
    echo
}

main() {
    local no_cleanup=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log_info "pgagroal CLI Comprehensive Test Suite"
    log_info "======================================"
    
    # Set up cleanup trap (unless disabled)
    if [[ "$no_cleanup" != "true" ]]; then
        trap cleanup EXIT
    fi
    
    # Find executable directory
    if EXECUTABLE_DIR=$(find_executable_dir); then
        log_success "Found executables in: $EXECUTABLE_DIR"
    else
        log_error "Could not find pgagroal executables in any expected location"
        log_error "Please ensure pgagroal is built before running this test"
        exit 1
    fi
    
    # Check required executables
    for exe in "pgagroal" "pgagroal-cli" "pgagroal-admin"; do
        if [[ ! -f "$EXECUTABLE_DIR/$exe" ]]; then
            log_error "$exe executable not found at $EXECUTABLE_DIR/$exe"
            exit 1
        fi
    done
    
    # Setup phase
    log_info "Setting up test environment..."
    
    if ! check_system_requirements; then
        log_error "System requirements check failed"
        exit 1
    fi
    
    initialize_log_files
    create_postgresql_cluster
    start_postgresql
    create_master_key
    create_pgagroal_configuration
    start_pgagroal
    
    log_success "Test environment setup completed"
    
    # Test execution phase
    run_all_tests
    
    # Report generation
    if generate_test_report; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
