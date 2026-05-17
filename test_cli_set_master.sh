#!/bin/bash

# pgagroal CLI CONF SET Master Tester
# Verifies all outcomes of the set command.
# Assumes pgagroal is running with config from CONF.

CLI="./build/src/pgagroal-cli"
CONF="${PGAGROAL_CONF:-./test_env/etc/pgagroal.conf}"

if [ ! -f "$CLI" ]; then
    echo "ERROR: CLI binary not found at $CLI"
    exit 1
fi

echo "=== pgagroal CLI Master Test Suite ==="
echo "Config: $CONF"

PASS=0
FAIL=0

run_test() {
    local key=$1
    local val=$2
    local expected=$3
    local desc=$4

    echo "[CASE] $desc"
    echo "  CMD: $CLI -c $CONF conf set $key $val"
    OUT=$($CLI -c $CONF conf set "$key" "$val" 2>&1)
    RET=$?

    echo "  OUT: $(echo "$OUT" | grep 'Status:' || echo "$OUT" | head -n 1)"

    # Verify memory state
    if [[ "$expected" == "HOT" ]]; then
       MEM=$($CLI -c $CONF conf get "$key" 2>/dev/null | tr -d '[:space:]')
       if [[ "$MEM" == *"$val"* ]]; then
          echo "  VERIFY: ✅ PASS (Applied to memory)"
          ((PASS++))
       else
          echo "  VERIFY: ❌ FAIL (Not in memory! Got: $MEM)"
          ((FAIL++))
       fi
    elif [[ "$expected" == "RESTART" ]]; then
       if [[ "$OUT" == *"restart"* ]] || [[ "$OUT" == *"Restart"* ]] || [[ "$OUT" == *"Requires"* ]]; then
          echo "  VERIFY: ✅ PASS (Restart required reported)"
          ((PASS++))
       else
          echo "  VERIFY: ❌ FAIL (Restart NOT reported!)"
          ((FAIL++))
       fi
    else
       if [[ $RET -ne 0 ]]; then
          echo "  VERIFY: ✅ PASS (Failed as expected)"
          ((PASS++))
       else
          echo "  VERIFY: ❌ FAIL (Succeeded unexpectedly!)"
          ((FAIL++))
       fi
    fi
    echo "------------------------------------------------"
}

# 1. HOT Changes (Success)
run_test "log_level" "info" "HOT" "Change log level at runtime"
run_test "blocking_timeout" "50" "HOT" "Change timeout at runtime"

# 2. SERVICE Changes (Restart Required)
run_test "port" "2346" "RESTART" "Change main port (Requires restart)"
run_test "metrics" "9901" "RESTART" "Change metrics port (Requires restart)"

# 3. Structural Changes (Restart Required)
# NOTE: max_connections can't be tested in DEBUG builds (MAX_NUMBER_OF_CONNECTIONS=8,
# any value gets clamped to 8 which equals the current value → no-op).
# Test pipeline with a value different from the running one:
run_test "pipeline" "session" "RESTART" "Change pipeline (Requires restart)"

# 4. Contextual Changes
run_test "server.primary.port" "5433" "RESTART" "Change backend server port"

# 5. Error Handling
run_test "invalid_key" "value" "FAIL" "Unknown parameter error"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
