#!/bin/bash
# Odoo DR - hourly replication window
#   0) skip if $PAUSE_FLAG exists; make sure the tunnel (if any) is up and the publisher answers
#   1) copy schema changes publisher -> DR (dr-schema-sync.sh) BEFORE any data flows (module installs / upgrades)
#   2) ENABLE the subscription (+ REFRESH PUBLICATION when the schema sync created new tables)
#   3) wait until the publisher slot confirmed everything up to the publisher's WAL position at window start
#      AND every table is ready
#   4) copy sequence values (dr-seq-sync.sh)
#   5) DISABLE the subscription (the slot keeps changes until the next window; capped by max_slot_wal_keep_size)
# Schedule : root crontab, every hour at :00
# Manual   : sudo dr-repl-window.sh [--keep-enabled]
# Config   : /etc/odoo-dr/dr.env (or $DR_ENV)
# Alerts   : $ALERTS + syslog (tag odoo-dr)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
PUB_PORT=${PUB_PORT:-5432}; TUNNEL_UNIT=${TUNNEL_UNIT:-}
ALERTS=${ALERTS:-$LOG_DIR/ALERTS.log}; PAUSE_FLAG=${PAUSE_FLAG:-/etc/odoo-dr/paused}
LOG=$LOG_DIR/dr-repl-window.log
LOCK=/run/lock/odoo-dr-repl-window.lock
REFRESH_FLAG=/run/odoo-dr-refresh-publication     # written by dr-schema-sync.sh after it created new tables
HERE=$(dirname "$(readlink -f "$0")")
KEEP=0
for a in "$@"; do case $a in --keep-enabled) KEEP=1 ;; *) echo "unknown option: $a"; exit 2 ;; esac; done

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }
alert() { log "ALERT: $*"; echo "$(date '+%F %T') repl-window: $*" >> "$ALERTS"; logger -t odoo-dr -p user.err "repl-window: $*"; }
exec 9>"$LOCK"; flock -n 9 || { log "previous window still running - exit"; exit 1; }

export PGCONNECT_TIMEOUT=30
# the password for $REPL_USER comes from ~postgres/.pgpass
PUB=(sudo -u postgres psql -X -w -At -v ON_ERROR_STOP=1 "host=$PUB_HOST port=$PUB_PORT dbname=$DB_NAME user=$REPL_USER sslmode=require")
DR=(sudo -u postgres psql -X -At -v ON_ERROR_STOP=1 -d "$DB_NAME")
errors() { "${DR[@]}" -c "select apply_error_count+sync_error_count from pg_stat_subscription_stats where subname='$SUB_NAME'"; }

log "===== window start (publisher $PUB_HOST:$PUB_PORT)"
if [ -e "$PAUSE_FLAG" ]; then log "===== window skipped: replication paused ($(cat "$PAUSE_FLAG"))"; exit 0; fi
RC=0
if [ -n "$TUNNEL_UNIT" ] && ! systemctl is-active -q "$TUNNEL_UNIT"; then
  log "tunnel down - restarting $TUNNEL_UNIT"; systemctl restart "$TUNNEL_UNIT"; sleep 10
fi
if ! "${PUB[@]}" -c "select 1" > /dev/null 2>&1; then
  alert "publisher unreachable at $PUB_HOST:$PUB_PORT - window skipped, the slot keeps the changes"
  exit 1
fi

"$HERE/dr-schema-sync.sh" > /dev/null 2>&1; SRC=$?
case $SRC in
  0) log "schema: $(grep "differences:" "$LOG_DIR/dr-schema-sync.log" | tail -1 | cut -d" " -f3-)" ;;
  3) log "schema sync applied changes WITH ALERTS (see dr-schema-sync.log)"; RC=1 ;;
  *) alert "schema sync failed rc=$SRC (see dr-schema-sync.log) - continuing; replication may stop on a missing column"; RC=1 ;;
esac

E0=$(errors)
"${DR[@]}" -c "ALTER SUBSCRIPTION $SUB_NAME ENABLE" > /dev/null || { alert "cannot enable subscription"; exit 1; }
if [ -e $REFRESH_FLAG ]; then
  if "${DR[@]}" -c "ALTER SUBSCRIPTION $SUB_NAME REFRESH PUBLICATION WITH (copy_data = true)" > /dev/null; then
    rm -f $REFRESH_FLAG; log "publication refreshed: new tables are being copied"
  else
    alert "REFRESH PUBLICATION failed - new tables are not replicated yet (retried next window)"; RC=1
  fi
fi

TARGET=$("${PUB[@]}" -c "select pg_current_wal_flush_lsn()") || { alert "publisher unreachable - subscription left ENABLED"; exit 1; }
log "target LSN $TARGET"
START=$(date +%s)
while :; do
  ROW=$("${PUB[@]}" -c "select coalesce(confirmed_flush_lsn::text,'-')||'|'||active::text||'|'||(confirmed_flush_lsn >= '$TARGET')::text||'|'||pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots where slot_name='$SLOT_NAME'" 2>/dev/null)
  IFS='|' read -r FLUSH ACTIVE DONE RETAINED <<< "$ROW"
  NOTREADY=$("${DR[@]}" -c "select count(*) from pg_subscription_rel where srsubstate <> 'r'")
  if [ "$DONE" = true ] && [ "$NOTREADY" = 0 ]; then log "caught up in $(( $(date +%s)-START )) s (confirmed $FLUSH, slot was holding $RETAINED)"; break; fi
  if [ "$(errors)" != "$E0" ]; then alert "new replication errors - see the PostgreSQL log"; RC=1; break; fi
  if [ $(( $(date +%s)-START )) -ge "$MAX_WAIT" ]; then alert "not caught up after ${MAX_WAIT}s (confirmed $FLUSH, active=$ACTIVE, tables not ready=$NOTREADY)"; RC=1; break; fi
  sleep 10
done

"$HERE/dr-seq-sync.sh" > /dev/null 2>&1 && log "sequences synced" || { alert "sequence sync failed (see dr-seq-sync.log)"; RC=1; }

if [ $KEEP -eq 1 ]; then
  log "subscription left ENABLED (--keep-enabled)"
else
  "${DR[@]}" -c "ALTER SUBSCRIPTION $SUB_NAME DISABLE" > /dev/null && log "subscription disabled until next window" || { alert "cannot disable subscription"; RC=1; }
fi
[ $RC -eq 0 ] && log "===== window OK" || log "===== window FAILED / WITH ALERTS"
exit $RC
