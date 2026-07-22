#!/usr/bin/env bash
#
# repro-923.sh - reproduce the #923 connection-handler stall under per-rule
# max_size oversubscription on the performance pipeline, per event backend.
#
# The listener stall strands clients whose worker is never forked: they hang
# past blocking_timeout with the main daemon idle. This harness drives
# 2 * MAX_SIZE concurrent held transactions and counts how many clients are
# served vs. stranded, looping TRIALS times and reporting a stall rate.
#
# Parameters (env):
#   EV_BACKEND   event backend to pin (io_uring | epoll | kqueue). default: kqueue
#   MAX_SIZE     per-rule max_size cap.                            default: 3
#   TRIALS       number of trials.                                 default: 6
#   HOLD         seconds each client holds its transaction.        default: 3
#   BLOCKING     pgagroal blocking_timeout (seconds).              default: 10
#   PG_PORT      backend PostgreSQL port.                          default: 5432
#   PG_USER      backend user / db.                                default: postgres / postgres
#
# Requires: a running PostgreSQL reachable at localhost:$PG_PORT with a
# trust-auth role $PG_USER owning database $PG_DB, plus built pgagroal and
# pgagroal-admin binaries. start-pg helper below spins one up via docker.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/build/src"
EV_BACKEND="${EV_BACKEND:-auto}"
MAX_SIZE="${MAX_SIZE:-3}"
TRIALS="${TRIALS:-6}"
HOLD="${HOLD:-3}"
BLOCKING="${BLOCKING:-10}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-postgres}"
PGAGROAL_PORT="${PGAGROAL_PORT:-2345}"
CLIENTS=$(( 2 * MAX_SIZE ))
# a client is "stranded" if it does not finish within blocking_timeout plus
# generous slack; a served client returns in ~HOLD (or times out cleanly at
# BLOCKING with "pool is full", which still counts as served, not stranded).
CLIENT_DEADLINE=$(( BLOCKING + HOLD + 8 ))

PSQL="${PSQL:-psql}"

CFG="$(mktemp -d)"
LOG="$CFG/pgagroal.log"

cleanup() {
   "$BIN/pgagroal-cli" -c "$CFG/pgagroal.conf" shutdown >/dev/null 2>&1
   # kill by port — FreeBSD uses sockstat instead of lsof
   local pid
   pid=$(sockstat -4lp "$PGAGROAL_PORT" 2>/dev/null | awk 'NR>1{print $3}' | head -1)
   [ -z "$pid" ] && pid=$(lsof -ti tcp:"$PGAGROAL_PORT" 2>/dev/null)
   [ -n "$pid" ] && kill "$pid" 2>/dev/null
   rm -rf "$CFG"
}
trap cleanup EXIT

write_config() {
   cat > "$CFG/pgagroal.conf" <<EOF
[pgagroal]
host = localhost
port = $PGAGROAL_PORT
log_type = file
log_level = debug5
log_path = $LOG
max_connections = 15
blocking_timeout = $BLOCKING
idle_timeout = 600
validation = off
unix_socket_dir = /tmp/
pipeline = performance
allow_unknown_users = false
$( [ "$EV_BACKEND" != "auto" ] && echo "ev_backend = $EV_BACKEND" )

[primary]
host = localhost
port = $PG_PORT
EOF
   echo "host all all all trust" > "$CFG/pgagroal_hba.conf"
   # DATABASE USER MAX_SIZE INITIAL_SIZE MIN_SIZE  (no prefill)
   echo "$PG_DB $PG_USER $MAX_SIZE 0 0" > "$CFG/pgagroal_databases.conf"
   : > "$CFG/pgagroal_users.conf"
   "$BIN/pgagroal-admin" -f "$CFG/pgagroal_users.conf" -U "$PG_USER" -P trust user add >/dev/null 2>&1
}

start_daemon() {
   "$BIN/pgagroal" -c "$CFG/pgagroal.conf" -a "$CFG/pgagroal_hba.conf" \
      -u "$CFG/pgagroal_users.conf" -l "$CFG/pgagroal_databases.conf" -d \
      >"$CFG/startup.log" 2>&1
   for _ in $(seq 1 20); do
      if "$PSQL" -h localhost -p "$PGAGROAL_PORT" -U "$PG_USER" -d "$PG_DB" \
            -tAc 'select 1' >/dev/null 2>&1; then
         return 0
      fi
      sleep 0.3
   done
   echo "daemon did not become ready; see $CFG/startup.log and $LOG" >&2
   return 1
}

run_trial() {
   local served=0 stranded=0 i rcfile
   rcfile="$CFG/rc"
   : > "$rcfile"
   for i in $(seq 1 "$CLIENTS"); do
      (
         # Portable per-client watchdog (no GNU `timeout` dependency): run psql
         # in the background, and a killer that fires after CLIENT_DEADLINE. A
         # served client (completes, or fails cleanly with "pool is full" at
         # blocking_timeout) exits before the deadline; a stranded client is
         # killed by the watchdog (exit > 128).
         "$PSQL" -h localhost -p "$PGAGROAL_PORT" -U "$PG_USER" -d "$PG_DB" \
            -tAc "BEGIN; SELECT pg_sleep($HOLD); COMMIT;" >/dev/null 2>&1 &
         cpid=$!
         ( sleep "$CLIENT_DEADLINE"; kill -9 "$cpid" 2>/dev/null ) &
         wpid=$!
         if wait "$cpid" 2>/dev/null; rc=$?; [ "$rc" -gt 128 ]; then
            echo stranded >> "$rcfile"     # killed by watchdog = hung
         else
            echo served >> "$rcfile"       # completed or clean pool-full error
         fi
         kill "$wpid" 2>/dev/null
      ) &
   done
   wait
   served=$(grep -c served "$rcfile")
   stranded=$(grep -c stranded "$rcfile")
   echo "$served $stranded"
}

echo "== #923 repro: backend=$EV_BACKEND max_size=$MAX_SIZE clients=$CLIENTS trials=$TRIALS =="
write_config
start_daemon || exit 1

total_stranded=0
for t in $(seq 1 "$TRIALS"); do
   read -r served stranded < <(run_trial)
   total_stranded=$(( total_stranded + stranded ))
   printf "trial %2d: served=%-2s stranded=%-2s\n" "$t" "$served" "$stranded"
done
echo "----"
echo "TOTAL stranded over $TRIALS trials: $total_stranded"
[ "$total_stranded" -eq 0 ] && echo "RESULT: clean" || echo "RESULT: STALL reproduced"
