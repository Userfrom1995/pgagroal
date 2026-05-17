#!/bin/bash

# pgagroal Configuration Reload Tester
# Verifies file-based reload behavior and atomicity.
# Uses test_env config (writable, safe to modify).

CLI="./build/src/pgagroal-cli"
CONF_FILE="${PGAGROAL_CONF:-./test_env/etc/pgagroal.conf}"
CONF_BAK="${CONF_FILE}.bak"

if [ ! -f "$CLI" ]; then
    echo "ERROR: CLI binary not found at $CLI"
    exit 1
fi

if [ ! -w "$CONF_FILE" ]; then
    echo "ERROR: Config file $CONF_FILE is not writable."
    exit 1
fi

# Save a backup of the original config to restore at the end
cp "$CONF_FILE" "$CONF_BAK"

PASS=0
FAIL=0

check_mem() {
    $CLI -c "$CONF_BAK" conf get "$1" 2>/dev/null | head -1
}

report() {
    local desc=$1
    local result=$2
    if [ "$result" -eq 0 ]; then
        echo "  ✅ PASS: $desc"
        ((PASS++))
    else
        echo "  ❌ FAIL: $desc"
        ((FAIL++))
    fi
}

# Safely change only the [pgagroal] section's port, not [primary]'s port
# Uses awk to only modify port in lines BEFORE the first server section
set_main_port() {
    local new_port=$1
    awk -v port="$new_port" '
        /^\[/ && !/^\[pgagroal\]/ { in_server=1 }
        /^port/ && !in_server { $0 = "port = " port }
        { print }
    ' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
}

echo "=== pgagroal Reload Behavior Suite ==="
echo "Config: $CONF_FILE"
echo ""

# Save original values
ORIG_LOG_LEVEL=$(check_mem "log_level" | tr -d '[:space:]')
ORIG_PORT=$(check_mem "port" | tr -d '[:space:]')

# Ensure baseline
sed -i "s/^log_level = .*/log_level = info/" "$CONF_FILE"
set_main_port "$ORIG_PORT"
$CLI -c "$CONF_FILE" conf reload > /dev/null 2>&1
sleep 1

echo "[CASE 1] HOT reload from file (log_level)"
sed -i "s/^log_level = .*/log_level = debug/" "$CONF_FILE"
$CLI -c "$CONF_FILE" conf reload > /dev/null 2>&1
sleep 1
MEM=$(check_mem "log_level" | tr -d '[:space:]')
if [[ "$MEM" == "debug" ]]; then
    report "log_level applied via reload (got: $MEM)" 0
else
    report "log_level applied via reload (expected debug, got: $MEM)" 1
fi
echo "------------------------------------------------"

echo "[CASE 2] Atomic deferral (HOT + SERVICE change)"
echo "  Changing log_level to warn AND port to 9999 in config file."
echo "  Expectation: Neither applied because port requires restart."

sed -i "s/^log_level = .*/log_level = warn/" "$CONF_FILE"
set_main_port "9999"
$CLI -c "$CONF_FILE" conf reload > /dev/null 2>&1
sleep 1

MEM_LOG=$(check_mem "log_level" | tr -d '[:space:]')
MEM_PORT=$(check_mem "port" | tr -d '[:space:]')

if [[ "$MEM_LOG" == "debug" ]]; then
    report "log_level preserved at debug (atomic deferral)" 0
else
    report "log_level preserved at debug (got: $MEM_LOG)" 1
fi

if [[ "$MEM_PORT" == *"$ORIG_PORT"* ]]; then
    report "port preserved at $ORIG_PORT (not mutated)" 0
else
    report "port preserved at $ORIG_PORT (got: $MEM_PORT)" 1
fi
echo "------------------------------------------------"

echo "[CASE 3] Recovery (fix file, reload should succeed)"
echo "  Restoring port to $ORIG_PORT, keeping log_level=warn."

set_main_port "$ORIG_PORT"
$CLI -c "$CONF_FILE" conf reload > /dev/null 2>&1
sleep 1

MEM_LOG=$(check_mem "log_level" | tr -d '[:space:]')
if [[ "$MEM_LOG" == *"warn"* ]]; then
    report "log_level now applied to warn after recovery" 0
else
    report "log_level now applied to warn (got: $MEM_LOG)" 1
fi
echo "------------------------------------------------"

# Restore original config from backup
cp "$CONF_BAK" "$CONF_FILE"
rm -f "$CONF_BAK"
$CLI -c "$CONF_FILE" conf reload > /dev/null 2>&1

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
