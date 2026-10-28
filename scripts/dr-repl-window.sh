#!/bin/bash
# Odoo DR - hourly replication window
#   1) ENABLE the subscription
#   2) wait until the publisher slot confirmed everything up to the publisher's WAL position at window start
#   3) copy sequence values (dr-seq-sync.sh)
#   4) DISABLE the subscription (the slot keeps changes until the next window; capped by max_slot_wal_keep_size)
# Schedule : root crontab, every hour at :00
# Manual   : sudo dr-repl-window.sh [--keep-enabled]
# Config   : /etc/odoo-dr/dr.env (or $DR_ENV)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
LOG=$LOG_DIR/dr-repl-window.log
LOCK=/run/lock/odoo-dr-repl-window.lock
HERE=$(dirname "$(readlink -f "$0")")
KEEP=0
for a in "$@"; do case $a in --keep-enabled) KEEP=1 ;; *) echo "unknown option: $a"; exit 2 ;; esac; done

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }
exec 9>"$LOCK"; flock -n 9 || { log "previous window still running - exit"; exit 1; }

export PGCONNECT_TIMEOUT=15
# the password for $REPL_USER comes from ~postgres/.pgpass
PUB=(sudo -u postgres psql -X -w -At -v ON_ERROR_STOP=1 "host=$PUB_HOST port=5432 dbname=$DB_NAME user=$REPL_USER sslmode=require")
DR=(sudo -u postgres psql -X -At -v ON_ERROR_STOP=1 -d "$DB_NAME")
errors() { "${DR[@]}" -c "select apply_error_count+sync_error_count from pg_stat_subscription_stats where subname='$SUB_NAME'"; }

log "===== window start (publisher $PUB_HOST)"
E0=$(errors)
"${DR[@]}" -c "ALTER SUBSCRIPTION $SUB_NAME ENABLE" > /dev/null || { log "ERROR: cannot enable subscription"; exit 1; }

TARGET=$("${PUB[@]}" -c "select pg_current_wal_flush_lsn()") || { log "ERROR: publisher unreachable - subscription left ENABLED"; exit 1; }
log "target LSN $TARGET"
START=$(date +%s); RC=0
while :; do
  ROW=$("${PUB[@]}" -c "select coalesce(confirmed_flush_lsn::text,'-')||'|'||active::text||'|'||(confirmed_flush_lsn >= '$TARGET')::text||'|'||pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots where slot_name='$SLOT_NAME'" 2>/dev/null)
  IFS='|' read -r FLUSH ACTIVE DONE RETAINED <<< "$ROW"
  if [ "$DONE" = true ]; then log "caught up in $(( $(date +%s)-START )) s (confirmed $FLUSH, slot was holding $RETAINED)"; break; fi
  if [ "$(errors)" != "$E0" ]; then log "ERROR: new replication errors - see the PostgreSQL log"; RC=1; break; fi
  if [ $(( $(date +%s)-START )) -ge "$MAX_WAIT" ]; then log "WARN: not caught up after ${MAX_WAIT}s (confirmed $FLUSH, active=$ACTIVE)"; RC=1; break; fi
  sleep 10
done

"$HERE/dr-seq-sync.sh" > /dev/null 2>&1 && log "sequences synced" || { log "ERROR: sequence sync failed"; RC=1; }

if [ $KEEP -eq 1 ]; then
  log "subscription left ENABLED (--keep-enabled)"
else
  "${DR[@]}" -c "ALTER SUBSCRIPTION $SUB_NAME DISABLE" > /dev/null && log "subscription disabled until next window" || { log "ERROR: cannot disable"; RC=1; }
fi
[ $RC -eq 0 ] && log "===== window OK" || log "===== window FAILED"
exit $RC
