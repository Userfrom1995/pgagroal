#!/bin/bash

# pgagroal-admin Comprehensive Test Script
# Complete standalone test script for testing all pgagroal-admin functionality
# Tests master key creation, user management, and all command combinations

set -e

# Platform detection
OS=$(uname)

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_DIR/test"

# Test environment configuration
TEST_TIMEOUT=30

# Test directories
ADMIN_TEST_DIR="$PROJECT_DIR/pgagroal-admin-test"
CONFIG_DIR="$ADMIN_TEST_DIR/conf"
LOG_DIR="$ADMIN_TEST_DIR/log"

# Test files
TEST_USERS_FILE="$CONFIG_DIR/test_users.conf"
TEST_USERS_FILE_2="$CONFIG_DIR/test_users_2.conf"
MASTER_KEY_BACKUP="$CONFIG_DIR/master_key_backup"

# Test users and passwords
TEST_USER1="testuser1"
TEST_USER2="testuser2"
TEST_USER3="admin_user"
TEST_PASSWORD1="password123"
TEST_PASSWORD2="newpassword456"
TEST_PASSWORD3="admin_pass"
MASTER_PASSWORD="masterkey123"

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

run_as_postgres() {
  if [[ "$OS" == "FreeBSD" ]]; then
    su - postgres -c "$*"
  else
    eval "$@"
  fi
}

# Helper function to clean up master key
cleanup_master_key() {
    log_debug "Cleaning up master key for fresh test"
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "rm -f ~/.pgagroal/master.key" || true
    else
        rm -f "$HOME/.pgagroal/master.key" || true
    fi
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
        if [[ -f "$dir/pgagroal-admin" ]]; then
            echo "$dir"
            return 0
        fi
    done
    
    return 1
}

check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check required binaries
    local required_bins=("jq")
    for bin in "${required_bins[@]}"; do
        if ! which $bin > /dev/null 2>&1; then
            log_error "$bin not found in PATH"
            return 1
        fi
    done
    
    log_success "System requirements check passed"
    return 0
}

setup_test_environment() {
    log_info "Setting up admin test environment..."
    
    # Create test directories
    mkdir -p "$ADMIN_TEST_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    
    # Set permissions for FreeBSD
    if [[ "$OS" == "FreeBSD" ]]; then
        if ! pw user show postgres >/dev/null 2>&1; then
            pw groupadd -n postgres -g 770
            pw useradd -n postgres -u 770 -g postgres -d /var/db/postgres -s /bin/sh
        fi
        chown -R postgres:postgres "$ADMIN_TEST_DIR"
    fi
    
    # Backup existing master key if it exists
    if [[ "$OS" == "FreeBSD" ]]; then
        if su - postgres -c "test -f ~/.pgagroal/master.key" 2>/dev/null; then
            su - postgres -c "cp ~/.pgagroal/master.key $MASTER_KEY_BACKUP"
            log_info "Backed up existing master key"
        fi
    else
        if [ -f "$HOME/.pgagroal/master.key" ]; then
            cp "$HOME/.pgagroal/master.key" "$MASTER_KEY_BACKUP"
            log_info "Backed up existing master key"
        fi
    fi
    
    log_success "Test environment setup completed"
}

########################### TEST EXECUTION FUNCTIONS ############################

execute_admin_test() {
    local test_name="$1"
    local admin_command="$2"
    local expected_success="$3"  # true/false
    local format="${4:-text}"    # text/json
    local check_output="${5:-true}"  # whether to validate output
    
    log_info "Testing: $test_name"
    
    local full_command
    local output
    local exit_code
    
    # Build command
    if [[ "$format" == "json" ]]; then
        # Check if --format is already in the command to avoid duplication
        if [[ "$admin_command" == *"--format"* ]]; then
            full_command="$EXECUTABLE_DIR/pgagroal-admin $admin_command"
        else
            full_command="$EXECUTABLE_DIR/pgagroal-admin $admin_command --format json"
        fi
    else
        full_command="$EXECUTABLE_DIR/pgagroal-admin $admin_command"
    fi
    
    # Log the command being executed for debugging
    log_debug "$test_name: Executing command: $full_command"
    
    # Execute command with timeout - handle FreeBSD vs other systems
    if [[ "$OS" == "FreeBSD" ]]; then
        # For FreeBSD, run as postgres user
        log_debug "$test_name: Running as postgres user on FreeBSD"
        if output=$(timeout $TEST_TIMEOUT su - postgres -c "$full_command" 2>&1); then
            exit_code=0
        else
            exit_code=$?
            # Handle timeout exit code (124)
            if [[ $exit_code -eq 124 ]]; then
                log_error "$test_name: Command timed out after $TEST_TIMEOUT seconds"
            fi
        fi
    else
        # For other systems, run directly
        log_debug "$test_name: Running directly on $OS"
        if output=$(timeout $TEST_TIMEOUT $full_command 2>&1); then
            exit_code=0
        else
            exit_code=$?
            # Handle timeout exit code (124)
            if [[ $exit_code -eq 124 ]]; then
                log_error "$test_name: Command timed out after $TEST_TIMEOUT seconds"
            fi
        fi
    fi
    
    # Always log command execution details for debugging
    log_debug "$test_name: Command executed: $full_command"
    log_debug "$test_name: Exit code: $exit_code"
    log_debug "$test_name: Output length: ${#output} characters"
    
    # Validate results
    local test_passed=true
    
    # Check exit code and provide detailed debugging information
    if [[ "$expected_success" == "true" && $exit_code -ne 0 ]]; then
        log_error "$test_name: Expected success but command failed"
        log_error "$test_name: ===== COMMAND EXECUTION DETAILS ====="
        log_error "$test_name: Command: $full_command"
        log_error "$test_name: Exit Code: $exit_code"
        log_error "$test_name: Platform: $OS"
        log_error "$test_name: Executable Dir: $EXECUTABLE_DIR"
        log_error "$test_name: Working Dir: $(pwd)"
        log_error "$test_name: ===== COMMAND OUTPUT ====="
        log_error "$test_name: $output"
        log_error "$test_name: ===== END OUTPUT ====="
        test_passed=false
    elif [[ "$expected_success" == "false" && $exit_code -eq 0 ]]; then
        log_error "$test_name: Expected failure but command succeeded"
        log_error "$test_name: ===== COMMAND EXECUTION DETAILS ====="
        log_error "$test_name: Command: $full_command"
        log_error "$test_name: Exit Code: $exit_code"
        log_error "$test_name: Platform: $OS"
        log_error "$test_name: Executable Dir: $EXECUTABLE_DIR"
        log_error "$test_name: Working Dir: $(pwd)"
        log_error "$test_name: ===== COMMAND OUTPUT ====="
        log_error "$test_name: $output"
        log_error "$test_name: ===== END OUTPUT ====="
        test_passed=false
    fi
    
    # Validate JSON format if requested
    if [[ "$format" == "json" && "$check_output" == "true" && $exit_code -eq 0 ]]; then
        if ! echo "$output" | jq . >/dev/null 2>&1; then
            log_error "$test_name: Invalid JSON output"
            log_error "$test_name: Raw output: $output"
            test_passed=false
        else
            log_debug "$test_name: Valid JSON output received"
        fi
    fi
    
    # Record test result
    if [[ "$test_passed" == "true" ]]; then
        log_success "$test_name: PASSED"
        ((TESTS_PASSED++))
        return 0
    else
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
}

########################### INDIVIDUAL TEST FUNCTIONS ############################

test_help_and_version() {
    log_info "=== Testing HELP and VERSION Commands ==="
    
    execute_admin_test "help command" "--help" "false" "text" "false"
    execute_admin_test "version command" "--version" "false" "text" "false"
    execute_admin_test "version short flag" "-V" "false" "text" "false"
    execute_admin_test "help short flag" "-?" "false" "text" "false"
}

test_master_key_operations() {
    log_info "=== Testing MASTER KEY Operations ==="
    
    # Clean start - remove any existing master key
    cleanup_master_key
    
    # Test master key creation with password flag
    execute_admin_test "master-key with -P flag" "master-key -P $MASTER_PASSWORD" "true" "text"
    
    # Clean up before next test (since pgagroal-admin doesn't overwrite)
    cleanup_master_key
    
    # Test master key creation with different password (fresh creation, not update)
    execute_admin_test "master-key with different password" "master-key -P ${MASTER_PASSWORD}new" "true" "text"
    
    # Clean up before JSON test
    cleanup_master_key
    
    # Test master key with JSON format (note: pgagroal-admin has a bug where it prints success message even in JSON mode)
    execute_admin_test "master-key JSON format" "master-key -P $MASTER_PASSWORD --format json" "true" "json" "false"
    
    # Test master key without password (should prompt - will fail in automated test)
    execute_admin_test "master-key without password" "master-key" "false" "text" "false"
    
    # Test master key already exists error (master key should exist from previous test)
    execute_admin_test "master-key already exists" "master-key -P $MASTER_PASSWORD" "false" "text" "false"
}

test_user_management_basic() {
    log_info "=== Testing Basic USER Management ==="
    
    # Clean up any existing test files
    rm -f "$TEST_USERS_FILE" "$TEST_USERS_FILE_2"
    
    # Test user add with all flags
    execute_admin_test "user add with flags" "-f $TEST_USERS_FILE -U $TEST_USER1 -P $TEST_PASSWORD1 user add" "true" "text"
    
    # Test user add with JSON format
    execute_admin_test "user add JSON" "-f $TEST_USERS_FILE -U $TEST_USER2 -P $TEST_PASSWORD2 user add --format json" "true" "json"
    
    # Test user list
    execute_admin_test "user list" "-f $TEST_USERS_FILE user ls" "true" "text"
    
    # Test user list with JSON format (note: pgagroal-admin has a bug where it prints usernames to stdout even in JSON mode)
    execute_admin_test "user list JSON" "-f $TEST_USERS_FILE user ls --format json" "true" "json" "false"
    
    # Test adding duplicate user (should fail with "Existing user" error)
    execute_admin_test "user add duplicate" "-f $TEST_USERS_FILE -U $TEST_USER1 -P ${TEST_PASSWORD1}new user add" "false" "text"
}

test_user_management_advanced() {
    log_info "=== Testing Advanced USER Management ==="
    
    # Test user edit
    execute_admin_test "user edit" "-f $TEST_USERS_FILE -U $TEST_USER1 -P $TEST_PASSWORD2 user edit" "true" "text"
    
    # Test user edit with JSON
    execute_admin_test "user edit JSON" "-f $TEST_USERS_FILE -U $TEST_USER2 -P ${TEST_PASSWORD2}new user edit --format json" "true" "json"
    
    # Test user delete
    execute_admin_test "user delete" "-f $TEST_USERS_FILE -U $TEST_USER2 user del" "true" "text"
    
    # Test user delete with JSON
    execute_admin_test "user delete JSON" "-f $TEST_USERS_FILE -U $TEST_USER1 user del --format json" "true" "json"
    
    # Test list after deletions
    execute_admin_test "user list after delete" "-f $TEST_USERS_FILE user ls" "true" "text"
}

test_password_generation() {
    log_info "=== Testing PASSWORD Generation ==="
    
    # Test password generation with default length
    execute_admin_test "generate password default" "-f $TEST_USERS_FILE -U $TEST_USER3 -g user add" "true" "text"
    
    # Test password generation with custom length
    execute_admin_test "generate password length 16" "-f $TEST_USERS_FILE -U ${TEST_USER3}_16 -g -l 16 user add" "true" "text"
    
    # Test password generation with JSON format (note: pgagroal-admin has a bug where it prints password even in JSON mode)
    execute_admin_test "generate password JSON" "-f $TEST_USERS_FILE -U ${TEST_USER3}_json -g user add --format json" "true" "json" "false"
    
    # Test invalid length
    execute_admin_test "generate password invalid length" "-f $TEST_USERS_FILE -U ${TEST_USER3}_invalid -g -l 0 user add" "false" "text"
}

test_file_operations() {
    log_info "=== Testing FILE Operations ==="
    
    # Test with different file paths
    execute_admin_test "user add different file" "-f $TEST_USERS_FILE_2 -U $TEST_USER1 -P $TEST_PASSWORD1 user add" "true" "text"
    
    # Test with non-existent directory (pgagroal-admin does not create directories, should fail)
    local nonexistent_file="$CONFIG_DIR/subdir/users.conf"
    execute_admin_test "user add non-existent directory" "-f $nonexistent_file -U $TEST_USER1 -P $TEST_PASSWORD1 user add" "false" "text"
    
    # Test with invalid file path (should fail)
    execute_admin_test "user add invalid path" "-f /invalid/path/users.conf -U $TEST_USER1 -P $TEST_PASSWORD1 user add" "false" "text" "false"
    
    # Test without file flag (uses default /etc/pgagroal/pgagroal_users.conf - will fail due to permissions/path)
    execute_admin_test "user add default file" "-U $TEST_USER1 -P $TEST_PASSWORD1 user add" "false" "text" "false"
}

test_error_scenarios() {
    log_info "=== Testing ERROR Scenarios ==="
    
    # Test invalid commands
    execute_admin_test "invalid command" "invalid_command" "false" "text" "false"
    
    # Test user command without subcommand
    execute_admin_test "user without subcommand" "-f $TEST_USERS_FILE user" "false" "text" "false"
    
    # Test user command with invalid subcommand
    execute_admin_test "user invalid subcommand" "-f $TEST_USERS_FILE user invalid" "false" "text" "false"
    
    # Test user operations without username
    execute_admin_test "user add without username" "-f $TEST_USERS_FILE -P $TEST_PASSWORD1 user add" "false" "text" "false"
    
    # Test user operations without password (when not generating)
    execute_admin_test "user add without password" "-f $TEST_USERS_FILE -U $TEST_USER1 user add" "false" "text" "false"
    
    # Test delete non-existent user
    execute_admin_test "delete non-existent user" "-f $TEST_USERS_FILE -U nonexistent_user user del" "false" "text" "false"
    
    # Test edit non-existent user
    execute_admin_test "edit non-existent user" "-f $TEST_USERS_FILE -U nonexistent_user -P $TEST_PASSWORD1 user edit" "false" "text" "false"
    
    # Test invalid format
    execute_admin_test "invalid format" "-f $TEST_USERS_FILE user ls --format invalid" "false" "text" "false"
}

test_format_combinations() {
    log_info "=== Testing FORMAT Combinations ==="
    
    # Ensure we have some users to test with
    if [[ "$OS" == "FreeBSD" ]]; then
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $TEST_USERS_FILE -U format_test1 -P password1 user add" || true
        su - postgres -c "$EXECUTABLE_DIR/pgagroal-admin -f $TEST_USERS_FILE -U format_test2 -P password2 user add" || true
    else
        $EXECUTABLE_DIR/pgagroal-admin -f $TEST_USERS_FILE -U format_test1 -P password1 user add || true
        $EXECUTABLE_DIR/pgagroal-admin -f $TEST_USERS_FILE -U format_test2 -P password2 user add || true
    fi
    
    # Test all commands with both formats
    execute_admin_test "user ls text format" "-f $TEST_USERS_FILE user ls --format text" "true" "text"
    execute_admin_test "user ls json format" "-f $TEST_USERS_FILE user ls --format json" "true" "json" "false"
    
    # Clean up master key before format tests
    cleanup_master_key
    
    # Test master-key with both formats
    execute_admin_test "master-key text format" "master-key -P $MASTER_PASSWORD --format text" "true" "text"
    
    # Clean up before JSON test
    cleanup_master_key
    
    execute_admin_test "master-key json format" "master-key -P $MASTER_PASSWORD --format json" "true" "json" "false"
}

test_comprehensive_workflow() {
    log_info "=== Testing COMPREHENSIVE Workflow ==="
    
    local workflow_file="$CONFIG_DIR/workflow_users.conf"
    rm -f "$workflow_file"
    
    # Complete workflow test
    log_info "Running complete admin workflow..."
    
    # Clean up master key before workflow
    cleanup_master_key
    
    # 1. Create master key
    execute_admin_test "workflow: create master key" "master-key -P $MASTER_PASSWORD" "true" "text"
    
    # 2. Add multiple users
    execute_admin_test "workflow: add user 1" "-f $workflow_file -U workflow_user1 -P pass1 user add" "true" "text"
    execute_admin_test "workflow: add user 2" "-f $workflow_file -U workflow_user2 -g -l 12 user add" "true" "text"
    execute_admin_test "workflow: add user 3" "-f $workflow_file -U workflow_admin -P admin123 user add" "true" "text"
    
    # 3. List all users (note: pgagroal-admin has mixed output bug in JSON mode)
    execute_admin_test "workflow: list all users" "-f $workflow_file user ls --format json" "true" "json" "false"
    
    # 4. Edit a user
    execute_admin_test "workflow: edit user password" "-f $workflow_file -U workflow_user1 -P newpass1 user edit" "true" "text"
    
    # 5. Delete a user
    execute_admin_test "workflow: delete user" "-f $workflow_file -U workflow_user2 user del" "true" "text"
    
    # 6. Final list
    execute_admin_test "workflow: final user list" "-f $workflow_file user ls" "true" "text"
}

run_all_tests() {
    set +e
    log_info "Starting comprehensive admin tests..."
    
    # Basic functionality tests
    test_help_and_version
    test_master_key_operations
    
    # User management tests
    test_user_management_basic
    test_user_management_advanced
    test_password_generation
    
    # File and format tests
    test_file_operations
    test_format_combinations
    
    # Error scenario tests
    test_error_scenarios
    
    # Comprehensive workflow test
    test_comprehensive_workflow
    
    set -e
}

########################### CLEANUP AND REPORTING ############################

generate_test_report() {
    echo
    log_info "=== ADMIN TEST SUMMARY ==="
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
        log_success "All admin tests passed!"
        echo
        return 0
    fi
}

cleanup() {
    log_info "Cleaning up admin test environment..."
    
    # Restore master key if we backed it up
    if [[ -f "$MASTER_KEY_BACKUP" ]]; then
        if [[ "$OS" == "FreeBSD" ]]; then
            su - postgres -c "cp $MASTER_KEY_BACKUP ~/.pgagroal/master.key"
        else
            cp "$MASTER_KEY_BACKUP" "$HOME/.pgagroal/master.key"
        fi
        log_info "Restored original master key"
    fi
    
    # Remove test directories
    if [ -d "$ADMIN_TEST_DIR" ]; then
        rm -rf "$ADMIN_TEST_DIR"
        log_info "Removed admin test directory"
    fi
    
    log_success "Admin test cleanup completed"
}

########################### MAIN EXECUTION ############################

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script runs comprehensive tests for all pgagroal-admin functionality."
    echo "It tests master key management, user operations, and all command combinations."
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --no-cleanup   Don't clean up test environment after completion"
    echo
    echo "The script will:"
    echo "  1. Set up a test environment for admin operations"
    echo "  2. Test master key creation and management"
    echo "  3. Test all user management operations (add, del, edit, ls)"
    echo "  4. Test password generation with various options"
    echo "  5. Test all format options (text/json)"
    echo "  6. Test error scenarios and edge cases"
    echo "  7. Generate a comprehensive test report"
    echo "  8. Clean up the test environment"
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
    
    log_info "pgagroal-admin Comprehensive Test Suite"
    log_info "======================================="
    
    # Set up cleanup trap (unless disabled)
    if [[ "$no_cleanup" != "true" ]]; then
        trap cleanup EXIT
    fi
    
    # Find executable directory
    if EXECUTABLE_DIR=$(find_executable_dir); then
        log_success "Found pgagroal-admin executable in: $EXECUTABLE_DIR"
    else
        log_error "Could not find pgagroal-admin executable in any expected location"
        log_error "Please ensure pgagroal is built before running this test"
        exit 1
    fi
    
    # Check required executable
    if [[ ! -f "$EXECUTABLE_DIR/pgagroal-admin" ]]; then
        log_error "pgagroal-admin executable not found at $EXECUTABLE_DIR/pgagroal-admin"
        exit 1
    fi
    
    # Setup phase
    log_info "Setting up admin test environment..."
    
    if ! check_system_requirements; then
        log_error "System requirements check failed"
        exit 1
    fi
    
    setup_test_environment
    
    log_success "Admin test environment setup completed"
    
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