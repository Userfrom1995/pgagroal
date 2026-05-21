#!/bin/bash

# pgagroal Health Check Worker Lifecycle Tester
# Tests dynamic start/stop of the health check worker via conf set.
#
# Prerequisites:
#   - pgagroal running with health_check enabled
#   - A valid health_check_user that can connect to the primary server
#   - PostgreSQL running and accessible

CLI="./build/src/pgagroal-cli"
CONF="${PGAGROAL_CONF:-./test_env/etc/pgagroal.conf}"

if [ ! -f "$CLI" ]; then
    echo "ERROR: CLI binary not found at $CLI"
    echo "Please run this from the project root or set the path."
    exit 1
fi

PASS=0
FAIL=0

check_health_worker() {
    pgrep -f "health check worker" > /dev/null 2>&1
    return $?
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

echo "=== Health Check Worker Lifecycle Suite ==="
echo "Config: $CONF"
echo ""

# Pre-check: verify health_check is enabled
HC=$($CLI -c $CONF conf get health_check 2>/dev/null | tr -d '[:space:]')
if [[ "$HC" != *"on"* ]] && [[ "$HC" != *"true"* ]] && [[ "$HC" != *"1"* ]]; then
    echo "⚠️  WARNING: health_check appears to be OFF ($HC)."
    echo "   Add these to your config and restart pgagroal:"
    echo "     health_check = on"
    echo "     health_check_period = 30"
    echo "     health_check_timeout = 5"
    echo "     health_check_user = postgres"
    echo ""
fi

# ─────────────────────────────────────────────
echo "[CASE 1] Verify worker is running at startup"
check_health_worker
report "Health check worker process exists" $?

# ─────────────────────────────────────────────
echo ""
echo "[CASE 2] conf set health_check off → worker should stop"
$CLI -c $CONF conf set health_check off > /dev/null 2>&1
sleep 3  # Give worker time to notice flag and exit

check_health_worker
if [ $? -ne 0 ]; then
    report "Worker stopped after health_check=off" 0
else
    report "Worker stopped after health_check=off" 1
fi

# Verify no zombie
ZOMBIES=$(ps aux | grep "health check" | grep -v grep | grep -c "defunct")
if [ "$ZOMBIES" -eq 0 ]; then
    report "No zombie process left behind" 0
else
    report "No zombie process left behind" 1
fi

# ─────────────────────────────────────────────
echo ""
echo "[CASE 3] conf set health_check on → worker should restart"
$CLI -c $CONF conf set health_check on > /dev/null 2>&1
sleep 3  # Give time for SIGUSR1 + fork

check_health_worker
report "Worker restarted after health_check=on" $?

# ─────────────────────────────────────────────
echo ""
echo "[CASE 4] conf set health_check_period → verify dynamic update"
echo "  Setting health_check_period to 10s..."
$CLI -c $CONF conf set health_check_period 10 > /dev/null 2>&1

MEM=$($CLI -c $CONF conf get health_check_period 2>/dev/null | head -1)
if [[ "$MEM" == *"10"* ]]; then
    report "health_check_period updated in memory to 10" 0
else
    report "health_check_period updated in memory to 10 (got: $MEM)" 1
fi

# ─────────────────────────────────────────────
echo ""
echo "[CASE 5] conf set health_check_timeout → verify dynamic update"
echo "  Setting health_check_timeout to 3s..."
$CLI -c $CONF conf set health_check_timeout 3 > /dev/null 2>&1

MEM=$($CLI -c $CONF conf get health_check_timeout 2>/dev/null | head -1)
if [[ "$MEM" == *"3"* ]]; then
    report "health_check_timeout updated in memory to 3" 0
else
    report "health_check_timeout updated in memory to 3 (got: $MEM)" 1
fi

# ─────────────────────────────────────────────
echo ""
echo "[CASE 6] SIGUSR1 → verify log rotation without crash"
PGAGROAL_PID=$(pgrep -f "pgagroal:" | head -1)
if [ -n "$PGAGROAL_PID" ]; then
    echo "  Sending SIGUSR1 to pgagroal (PID $PGAGROAL_PID)..."
    kill -USR1 "$PGAGROAL_PID"
    sleep 2

    # Check pgagroal is still alive
    kill -0 "$PGAGROAL_PID" 2>/dev/null
    report "pgagroal still running after SIGUSR1" $?

    # Check health worker is still alive (if it was running)
    check_health_worker
    report "Health check worker still running after SIGUSR1" $?
else
    report "Could not find pgagroal PID for SIGUSR1 test" 1
fi

# ─────────────────────────────────────────────
echo ""
echo "[CASE 7] conf set port → verify restart_required and NO mutation"
BEFORE=$($CLI -c $CONF conf get port 2>/dev/null | head -1)
OUT=$($CLI -c $CONF conf set port 9999 2>&1)
AFTER=$($CLI -c $CONF conf get port 2>/dev/null | head -1)

if [[ "$OUT" == *"restart"* ]] || [[ "$OUT" == *"Restart"* ]] || [[ "$OUT" == *"Requires"* ]]; then
    report "Port change returned restart_required" 0
else
    report "Port change returned restart_required (got: $OUT)" 1
fi

if [ "$BEFORE" == "$AFTER" ]; then
    report "Port value unchanged in memory ($BEFORE → $AFTER)" 0
else
    report "Port value unchanged in memory ($BEFORE → $AFTER)" 1
fi

# ─────────────────────────────────────────────
# Restore defaults
echo ""
echo "Restoring health_check_period to 30 and timeout to 5..."
$CLI -c $CONF conf set health_check_period 30 > /dev/null 2>&1
$CLI -c $CONF conf set health_check_timeout 5 > /dev/null 2>&1

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
