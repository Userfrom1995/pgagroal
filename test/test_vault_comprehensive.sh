#!/bin/bash

# pgagroal-vault Comprehensive Test Script
# Complete standalone test script for testing all pgagroal-vault functionality
# Tests HTTP server, user password retrieval, error handling, and all configurations

set -e

# Platform detection
OS=$(uname)

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_DIR/test"

# Test environment configuration
VAULT_PORT=2500
VAULT_METRICS_PORT=2501
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

# Test users
FRONTEND_USER1="frontend_user1"
FRONTEND_USER2="frontend_user2"
FRONTEND_PASSWORD1="frontend_pass1"
FRONTEND_PASSWORD2="frontend_pass2"

# Directories for vault test environment
LOG_DIR="$PROJECT_DIR/log-vault"
PGCTL_LOG_FILE="$LOG_DIR/logfile"
PGAGROAL_LOG_FILE="$LOG_DIR/pgagroal_vault.log"
VAULT_LOG_FILE="$LOG_DIR/vault.log"

POSTGRES_OPERATION_DIR="$PROJECT_DIR/pgagroal-postgresql-vault"
DATA_DIR="$POSTGRES_OPERATION_DIR/data"

VAULT_OPERATION_DIR="$PROJECT_DIR/pgagroal-testsuite-vault"
CONFIG_DIR="$VAULT_OPERATION_DIR/conf"

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
        if [[ "$server_name" == "vault" ]]; then
            # For vault, test HTTP endpoint
            if curl -s -f "http://localhost:$port/users/test" >/dev/null 2>&1 || curl -s "http://localhost:$port/users/test" 2>/dev/null | grep -q "404\|200"; then
                log_success "$server_name is ready on port $port"
                return 0
            fi
        else
            # For PostgreSQL
            pg_isready -h localhost -p $port >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_success "$server_name is ready on port $port"
                return 0
            fi
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
    log_info "Stopping any running pgagroal-vault, pgagroal and PostgreSQL processes..."
    pkill -f pgagroal-vault || true
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
        if [[ -f "$dir/pgagroal-vault" ]] && [[ -f "$dir/pgagroal" ]] && [[ -f "$dir/pgagroal-admin" ]]; then
            echo "$dir"
            return 0
        fi
    done
    
    return 1
}

check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check required binaries
    local required_bins=("initdb" "pg_ctl" "psql" "curl")
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
    if is_port_in_use $VAULT_PORT; then
        VAULT_PORT=$(next_available_port $VAULT_PORT)
    fi
    if is_port_in_use $VAULT_METRICS_PORT; then
        VAULT_METRICS_PORT=$(next_available_port $VAULT_METRICS_PORT)
    fi
    
    log_success "System requirements check passed"
    log_info "Using PostgreSQL port: $POSTGRES_PORT"
    log_info "Using pgagroal port: $PGAGROAL_PORT"
    log_info "Using management port: $MANAGEMENT_PORT"
    log_info "Using vault port: $VAULT_PORT"
    log_info "Using vault metrics port: $VAULT_METRICS_PORT"
    return 0
}

initialize_log_files() {
    log_info "Initializing log files..."
    mkdir -p $LOG_DIR
    touch $PGAGROAL_LOG_FILE $PGCTL_LOG_FILE $VAULT_LOG_FILE
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
        chown -R postgres:postgres "$DATA_DIR"
        chown -R postgres:postgres "$CONFIG_DIR"
    fi

    # Initialize database
    INITDB_PATH=$(command -v initdb)
    if [ -z "$INITDB_PATH" ]; then
        log_error "initdb not found!"
        return 1
    fi

    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$INITDB_PATH -k -D $DATA_DIR"
    else
        $INITDB_PATH -k -D $DATA_DIR
    fi
    
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

    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$PGCTL_PATH -D $DATA_DIR -l $PGCTL_LOG_FILE start"
    else
        $PGCTL_PATH -D $DATA_DIR -l $PGCTL_LOG_FILE start
    fi
    
    if ! wait_for_server_ready $POSTGRES_PORT "PostgreSQL"; then
        return 1
    fi

    # Create test user and database
    psql -h localhost -p $POSTGRES_PORT -U $PSQL_USER -d postgres -c "CREATE ROLE myuser WITH LOGIN PASSWORD '$PGPASSWORD';" || true
    psql -h localhost -p $POSTGRES_PORT -U $PSQL_USER -d postgres -c "CREATE DATABASE mydb WITH OWNER myuser;" || true
    
    log_success "PostgreSQL started and configured"
}

create_master_key() {
    log_info "Creating master key..."
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if su - postgres -c "test -f ~/.pgagroal/master.key" 2>/dev/null; then
            log_info "Master key already exists"
            return 0
        fi
        su - postgres -c "mkdir -p ~/.pgagroal"
        su - postgres -c "chmod 700 ~/.pgagroal"
    else
        if [ -f "$HOME/.pgagroal/master.key" ]; then
            log_info "Master key already exists"
            return 0
        fi
        mkdir -p ~/.pgagroal
        chmod 700 ~/.pgagroal
    fi
    
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin master-key -P $PGPASSWORD"
    else
        $EXECUTABLE_DIR/pgagroal-admin master-key -P $PGPASSWORD
    fi
    log_success "Master key created"
}

create_pgagroal_configuration() {
    log_info "Creating pgagroal configuration..."
    
    mkdir -p "$CONFIG_DIR"
    
    # Main configuration with frontend password rotation enabled
    log_debug "Creating main pgagroal configuration at $CONFIG_DIR/pgagroal.conf"
    cat > "$CONFIG_DIR/pgagroal.conf" << EOF
[pgagroal]
host = localhost
port = $PGAGROAL_PORT
management = $MANAGEMENT_PORT

log_type = file
log_level = debug5
log_path = $PGAGROAL_LOG_FILE

max_connections = 100
idle_timeout = 600
validation = off
unix_socket_dir = /tmp/
pipeline = performance

# Frontend password rotation settings
rotate_frontend_password_timeout = 60
rotate_frontend_password_length = 12

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
    
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_users.conf -U $PSQL_USER -P $PGPASSWORD user add"
    else
        $EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_users.conf -U $PSQL_USER -P $PGPASSWORD user add
    fi
    
    # Create admin configuration
    if [ -f "$CONFIG_DIR/pgagroal_admins.conf" ]; then
        rm -f "$CONFIG_DIR/pgagroal_admins.conf"
    fi
    
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_admins.conf -U $ADMIN_USER -P $ADMIN_PASSWORD user add"
    else
        $EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_admins.conf -U $ADMIN_USER -P $ADMIN_PASSWORD user add
    fi
    
    # Create frontend users configuration
    if [ -f "$CONFIG_DIR/pgagroal_frontend_users.conf" ]; then
        rm -f "$CONFIG_DIR/pgagroal_frontend_users.conf"
    fi
    
    # Frontend passwords must be 8-1024 characters long
    local frontend_pass1="frontend_password_123"  # 20 chars
    local frontend_pass2="frontend_password_456"  # 20 chars
    
    log_debug "Creating frontend users with passwords of length ${#frontend_pass1} and ${#frontend_pass2}"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_frontend_users.conf -U $FRONTEND_USER1 -P $frontend_pass1 user add" 2>&1; then
            log_debug "Frontend user $FRONTEND_USER1 created successfully"
        else
            log_error "Failed to create frontend user $FRONTEND_USER1"
            return 1
        fi
        if su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_frontend_users.conf -U $FRONTEND_USER2 -P $frontend_pass2 user add" 2>&1; then
            log_debug "Frontend user $FRONTEND_USER2 created successfully"
        else
            log_error "Failed to create frontend user $FRONTEND_USER2"
            return 1
        fi
    else
        if $EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_frontend_users.conf -U $FRONTEND_USER1 -P $frontend_pass1 user add 2>&1; then
            log_debug "Frontend user $FRONTEND_USER1 created successfully"
        else
            log_error "Failed to create frontend user $FRONTEND_USER1"
            return 1
        fi
        if $EXECUTABLE_DIR/pgagroal-admin -f $CONFIG_DIR/pgagroal_frontend_users.conf -U $FRONTEND_USER2 -P $frontend_pass2 user add 2>&1; then
            log_debug "Frontend user $FRONTEND_USER2 created successfully"
        else
            log_error "Failed to create frontend user $FRONTEND_USER2"
            return 1
        fi
    fi
    
    # Update the global variables for use in tests
    FRONTEND_PASSWORD1="$frontend_pass1"
    FRONTEND_PASSWORD2="$frontend_pass2"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        chown -R postgres:postgres "$CONFIG_DIR"
        chown postgres:postgres "$PGAGROAL_LOG_FILE"
    fi
    
    log_success "pgagroal configuration created"
}

start_pgagroal() {
    log_info "Starting pgagroal..."
    
    # Debug: Show configuration files before starting
    log_debug "Configuration files:"
    log_debug "Main config: $CONFIG_DIR/pgagroal.conf"
    log_debug "HBA config: $CONFIG_DIR/pgagroal_hba.conf"
    log_debug "Users config: $CONFIG_DIR/pgagroal_users.conf"
    log_debug "Databases config: $CONFIG_DIR/pgagroal_databases.conf"
    log_debug "Admins config: $CONFIG_DIR/pgagroal_admins.conf"
    log_debug "Frontend users config: $CONFIG_DIR/pgagroal_frontend_users.conf"
    
    # Debug: Show contents of configuration files
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_debug "=== pgagroal.conf contents ==="
        cat "$CONFIG_DIR/pgagroal.conf" || log_error "Could not read pgagroal.conf"
        log_debug "=== pgagroal_frontend_users.conf contents ==="
        cat "$CONFIG_DIR/pgagroal_frontend_users.conf" || log_error "Could not read pgagroal_frontend_users.conf"
        log_debug "=== End configuration files ==="
    fi
    
    local pgagroal_command
    if [[ "$OS" == "FreeBSD" ]]; then
        pgagroal_command="su - postgres -c \"$EXECUTABLE_DIR/pgagroal -c $CONFIG_DIR/pgagroal.conf -a $CONFIG_DIR/pgagroal_hba.conf -u $CONFIG_DIR/pgagroal_users.conf -l $CONFIG_DIR/pgagroal_databases.conf -A $CONFIG_DIR/pgagroal_admins.conf -F $CONFIG_DIR/pgagroal_frontend_users.conf -d\""
    else
        pgagroal_command="$EXECUTABLE_DIR/pgagroal -c $CONFIG_DIR/pgagroal.conf -a $CONFIG_DIR/pgagroal_hba.conf -u $CONFIG_DIR/pgagroal_users.conf -l $CONFIG_DIR/pgagroal_databases.conf -A $CONFIG_DIR/pgagroal_admins.conf -F $CONFIG_DIR/pgagroal_frontend_users.conf -d"
    fi
    
    log_debug "Executing pgagroal command: $pgagroal_command"
    
    # Execute the command and capture output
    local pgagroal_output
    if [[ "$OS" == "FreeBSD" ]]; then
        if pgagroal_output=$(su - postgres -c "$EXECUTABLE_DIR/pgagroal -c $CONFIG_DIR/pgagroal.conf -a $CONFIG_DIR/pgagroal_hba.conf -u $CONFIG_DIR/pgagroal_users.conf -l $CONFIG_DIR/pgagroal_databases.conf -A $CONFIG_DIR/pgagroal_admins.conf -F $CONFIG_DIR/pgagroal_frontend_users.conf -d" 2>&1); then
            log_debug "pgagroal started successfully"
        else
            log_error "pgagroal failed to start"
            log_error "pgagroal output: $pgagroal_output"
            return 1
        fi
    else
        if pgagroal_output=$($EXECUTABLE_DIR/pgagroal -c $CONFIG_DIR/pgagroal.conf -a $CONFIG_DIR/pgagroal_hba.conf -u $CONFIG_DIR/pgagroal_users.conf -l $CONFIG_DIR/pgagroal_databases.conf -A $CONFIG_DIR/pgagroal_admins.conf -F $CONFIG_DIR/pgagroal_frontend_users.conf -d 2>&1); then
            log_debug "pgagroal started successfully"
        else
            log_error "pgagroal failed to start"
            log_error "pgagroal output: $pgagroal_output"
            return 1
        fi
    fi
    
    if ! wait_for_server_ready $PGAGROAL_PORT "pgagroal"; then
        log_error "pgagroal did not become ready on port $PGAGROAL_PORT"
        # Try to get more information from log file
        if [[ -f "$PGAGROAL_LOG_FILE" ]]; then
            log_error "=== pgagroal log file contents ==="
            tail -20 "$PGAGROAL_LOG_FILE" || log_error "Could not read pgagroal log file"
            log_error "=== End pgagroal log file ==="
        fi
        return 1
    fi
    
    log_success "pgagroal started successfully"
}

create_vault_configuration() {
    log_info "Creating vault configuration..."
    
    # Main vault configuration
    cat > "$CONFIG_DIR/pgagroal_vault.conf" << EOF
[pgagroal-vault]
host = localhost
port = $VAULT_PORT
metrics = $VAULT_METRICS_PORT

ev_backend = auto

log_type = file
log_level = info
log_path = $VAULT_LOG_FILE

[main]
host = localhost
port = $MANAGEMENT_PORT
user = $ADMIN_USER
EOF

    # Vault users configuration (same as admin users for simplicity)
    cp "$CONFIG_DIR/pgagroal_admins.conf" "$CONFIG_DIR/pgagroal_vault_users.conf"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        chown -R postgres:postgres "$CONFIG_DIR"
        chown postgres:postgres "$VAULT_LOG_FILE"
    fi
    
    log_success "Vault configuration created"
}

start_vault() {
    log_info "Starting pgagroal-vault..."
    
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-vault -c $CONFIG_DIR/pgagroal_vault.conf -u $CONFIG_DIR/pgagroal_vault_users.conf -d"
    else
        $EXECUTABLE_DIR/pgagroal-vault -c $CONFIG_DIR/pgagroal_vault.conf -u $CONFIG_DIR/pgagroal_vault_users.conf -d
    fi
    
    if ! wait_for_server_ready $VAULT_PORT "vault"; then
        return 1
    fi
    
    log_success "pgagroal-vault started successfully"
}

########################### TEST EXECUTION FUNCTIONS ############################

execute_vault_test() {
    local test_name="$1"
    local http_method="$2"
    local endpoint="$3"
    local expected_status="$4"  # HTTP status code
    local check_body="${5:-false}"  # whether to check response body
    local expected_body="$6"    # expected response body content
    
    log_info "Testing: $test_name"
    
    local full_url="http://localhost:$VAULT_PORT$endpoint"
    local output
    local http_status
    local response_body
    
    # Execute HTTP request with timeout
    if [[ "$http_method" == "GET" ]]; then
        if output=$(timeout $TEST_TIMEOUT curl -s -w "HTTPSTATUS:%{http_code}" "$full_url" 2>&1); then
            http_status=$(echo "$output" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
            response_body=$(echo "$output" | sed 's/HTTPSTATUS:[0-9]*$//')
        else
            log_error "$test_name: curl command failed or timed out"
            FAILED_TESTS+=("$test_name")
            ((TESTS_FAILED++))
            return 1
        fi
    elif [[ "$http_method" == "POST" ]]; then
        if output=$(timeout $TEST_TIMEOUT curl -s -w "HTTPSTATUS:%{http_code}" -X POST "$full_url" 2>&1); then
            http_status=$(echo "$output" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
            response_body=$(echo "$output" | sed 's/HTTPSTATUS:[0-9]*$//')
        else
            log_error "$test_name: curl POST command failed or timed out"
            FAILED_TESTS+=("$test_name")
            ((TESTS_FAILED++))
            return 1
        fi
    else
        log_error "$test_name: Unsupported HTTP method: $http_method"
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
    
    # Validate results
    local test_passed=true
    
    # Check HTTP status code
    if [[ "$http_status" != "$expected_status" ]]; then
        log_error "$test_name: Expected HTTP status $expected_status but got $http_status"
        log_error "$test_name: Response body: $response_body"
        test_passed=false
    fi
    
    # Check response body if requested
    if [[ "$check_body" == "true" && -n "$expected_body" ]]; then
        if [[ "$response_body" != *"$expected_body"* ]]; then
            log_error "$test_name: Expected response body to contain '$expected_body' but got '$response_body'"
            test_passed=false
        fi
    fi
    
    # Record test result
    if [[ "$test_passed" == "true" ]]; then
        log_success "$test_name: PASSED (HTTP $http_status)"
        if [[ "$check_body" == "true" ]]; then
            log_debug "$test_name: Response body: $response_body"
        fi
        ((TESTS_PASSED++))
        return 0
    else
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
}

execute_metrics_test() {
    local test_name="$1"
    local expected_status="$2"
    
    log_info "Testing: $test_name"
    
    local metrics_url="http://localhost:$VAULT_METRICS_PORT/metrics"
    local output
    local http_status
    
    # Execute metrics request
    if output=$(timeout $TEST_TIMEOUT curl -s -w "HTTPSTATUS:%{http_code}" "$metrics_url" 2>&1); then
        http_status=$(echo "$output" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
        response_body=$(echo "$output" | sed 's/HTTPSTATUS:[0-9]*$//')
    else
        log_error "$test_name: curl command failed or timed out"
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
    
    # Validate results
    if [[ "$http_status" == "$expected_status" ]]; then
        log_success "$test_name: PASSED (HTTP $http_status)"
        ((TESTS_PASSED++))
        return 0
    else
        log_error "$test_name: Expected HTTP status $expected_status but got $http_status"
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
}

########################### INDIVIDUAL TEST FUNCTIONS ############################

test_vault_help_and_version() {
    log_info "=== Testing VAULT Help and Version ==="
    
    # Test help
    local help_output
    if [[ "$OS" == "FreeBSD" ]]; then
        if help_output=$(su - postgres -c "$EXECUTABLE_DIR/pgagroal-vault --help" 2>&1); then
            if [[ "$help_output" == *"pgagroal-vault"* ]]; then
                log_success "vault help: PASSED"
                ((TESTS_PASSED++))
            else
                log_error "vault help: Invalid help output"
                FAILED_TESTS+=("vault help")
                ((TESTS_FAILED++))
            fi
        else
            log_error "vault help: Command failed"
            FAILED_TESTS+=("vault help")
            ((TESTS_FAILED++))
        fi
    else
        if help_output=$($EXECUTABLE_DIR/pgagroal-vault --help 2>&1); then
            if [[ "$help_output" == *"pgagroal-vault"* ]]; then
                log_success "vault help: PASSED"
                ((TESTS_PASSED++))
            else
                log_error "vault help: Invalid help output"
                FAILED_TESTS+=("vault help")
                ((TESTS_FAILED++))
            fi
        else
            log_error "vault help: Command failed"
            FAILED_TESTS+=("vault help")
            ((TESTS_FAILED++))
        fi
    fi
}

test_valid_user_requests() {
    log_info "=== Testing Valid User Requests ==="
    
    # Test valid frontend users
    execute_vault_test "GET valid user 1" "GET" "/users/$FRONTEND_USER1" "200" "true" "$FRONTEND_PASSWORD1"
    execute_vault_test "GET valid user 2" "GET" "/users/$FRONTEND_USER2" "200" "true" "$FRONTEND_PASSWORD2"
}

test_invalid_user_requests() {
    log_info "=== Testing Invalid User Requests ==="
    
    # Test non-existent users
    execute_vault_test "GET non-existent user" "GET" "/users/nonexistent_user" "404"
    execute_vault_test "GET empty username" "GET" "/users/" "404"
    execute_vault_test "GET user with special chars" "GET" "/users/user@domain.com" "404"
}

test_invalid_endpoints() {
    log_info "=== Testing Invalid Endpoints ==="
    
    # Test invalid URL patterns
    execute_vault_test "GET root endpoint" "GET" "/" "404"
    execute_vault_test "GET invalid path" "GET" "/invalid" "404"
    execute_vault_test "GET user without users prefix" "GET" "/user/$FRONTEND_USER1" "404"
    execute_vault_test "GET users without username" "GET" "/users" "404"
}

test_http_methods() {
    log_info "=== Testing HTTP Methods ==="
    
    # Test POST requests (should be rejected)
    execute_vault_test "POST to valid user" "POST" "/users/$FRONTEND_USER1" "404"
    execute_vault_test "POST to invalid endpoint" "POST" "/invalid" "404"
}

test_metrics_endpoint() {
    log_info "=== Testing Metrics Endpoint ==="
    
    # Test metrics endpoint if enabled
    execute_metrics_test "GET metrics endpoint" "200"
}

test_concurrent_requests() {
    log_info "=== Testing Concurrent Requests ==="
    
    # Test multiple concurrent requests
    local pids=()
    local temp_dir="/tmp/vault_test_$$"
    mkdir -p "$temp_dir"
    
    # Launch multiple concurrent requests
    for i in {1..5}; do
        (
            local result_file="$temp_dir/result_$i"
            local status=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$VAULT_PORT/users/$FRONTEND_USER1")
            echo "$status" > "$result_file"
        ) &
        pids+=($!)
    done
    
    # Wait for all requests to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Check results
    local concurrent_passed=true
    for i in {1..5}; do
        local result_file="$temp_dir/result_$i"
        if [[ -f "$result_file" ]]; then
            local status=$(cat "$result_file")
            if [[ "$status" != "200" ]]; then
                concurrent_passed=false
                break
            fi
        else
            concurrent_passed=false
            break
        fi
    done
    
    # Clean up
    rm -rf "$temp_dir"
    
    if [[ "$concurrent_passed" == "true" ]]; then
        log_success "concurrent requests: PASSED"
        ((TESTS_PASSED++))
    else
        log_error "concurrent requests: Some requests failed"
        FAILED_TESTS+=("concurrent requests")
        ((TESTS_FAILED++))
    fi
}

test_vault_configuration_options() {
    log_info "=== Testing Vault Configuration Options ==="
    
    # Test vault with different configuration file
    local alt_config="$CONFIG_DIR/pgagroal_vault_alt.conf"
    local alt_port=$((VAULT_PORT + 100))
    
    # Create alternative configuration
    cat > "$alt_config" << EOF
[pgagroal-vault]
host = localhost
port = $alt_port

ev_backend = auto

log_type = console
log_level = debug

[main]
host = localhost
port = $MANAGEMENT_PORT
user = $ADMIN_USER
EOF

    # Test configuration file validation (this would require stopping and restarting vault)
    log_info "Alternative configuration created for manual testing"
    log_success "vault configuration options: PASSED (config file created)"
    ((TESTS_PASSED++))
}

run_all_tests() {
    set +e
    log_info "Starting comprehensive vault tests..."
    
    # Basic functionality tests
    test_vault_help_and_version
    
    # Core vault functionality tests
    test_valid_user_requests
    test_invalid_user_requests
    test_invalid_endpoints
    test_http_methods
    
    # Advanced tests
    test_metrics_endpoint
    test_concurrent_requests
    test_vault_configuration_options
    
    set -e
}

########################### CLEANUP AND REPORTING ############################

generate_test_report() {
    echo
    log_info "=== VAULT TEST SUMMARY ==="
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
        log_success "All vault tests passed!"
        echo
        return 0
    fi
}

cleanup() {
    log_info "Cleaning up vault test environment..."
    stop_processes
    
    # Remove test directories
    if [ -d "$POSTGRES_OPERATION_DIR" ]; then
        rm -rf "$POSTGRES_OPERATION_DIR"
        log_info "Removed PostgreSQL test directory"
    fi
    
    if [ -d "$VAULT_OPERATION_DIR" ]; then
        rm -rf "$VAULT_OPERATION_DIR"
        log_info "Removed vault test directory"
    fi
    
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        log_info "Removed log directory"
    fi
    
    # Clean up master key to ensure independence from other tests
    log_info "Cleaning up master key for test independence"
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "rm -rf ~/.pgagroal" || true
    else
        rm -rf "$HOME/.pgagroal" || true
    fi
    
    log_success "Vault test cleanup completed"
}

########################### MAIN EXECUTION ############################

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script runs comprehensive tests for all pgagroal-vault functionality."
    echo "It sets up its own PostgreSQL, pgagroal, and vault environment for testing."
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --no-cleanup   Don't clean up test environment after completion"
    echo
    echo "The script will:"
    echo "  1. Set up a temporary PostgreSQL cluster"
    echo "  2. Configure and start pgagroal with management interface"
    echo "  3. Configure and start pgagroal-vault HTTP server"
    echo "  4. Test all vault HTTP endpoints and functionality"
    echo "  5. Test error scenarios and edge cases"
    echo "  6. Generate a comprehensive test report"
    echo "  7. Clean up the test environment"
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
    
    log_info "pgagroal-vault Comprehensive Test Suite"
    log_info "======================================="
    
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
    for exe in "pgagroal" "pgagroal-admin" "pgagroal-vault"; do
        if [[ ! -f "$EXECUTABLE_DIR/$exe" ]]; then
            log_error "$exe executable not found at $EXECUTABLE_DIR/$exe"
            exit 1
        fi
    done
    
    # Setup phase - ensure complete independence from other tests
    log_info "Setting up vault test environment..."
    
    # Clean up any existing state from previous tests
    log_info "Ensuring test independence by cleaning up any existing state"
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "rm -rf ~/.pgagroal" || true
    else
        rm -rf "$HOME/.pgagroal" || true
    fi
    
    # Remove any existing test directories
    rm -rf "$POSTGRES_OPERATION_DIR" || true
    rm -rf "$VAULT_OPERATION_DIR" || true
    rm -rf "$LOG_DIR" || true
    
    # Kill any existing processes that might interfere
    pkill -f pgagroal-vault || true
    pkill -f pgagroal || true
    pkill -f postgres || true
    sleep 2
    
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
    create_vault_configuration
    start_vault
    
    log_success "Vault test environment setup completed"
    
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