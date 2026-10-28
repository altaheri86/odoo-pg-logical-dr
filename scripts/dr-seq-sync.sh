#!/bin/bash
# Odoo DR - copy PostgreSQL sequence values publisher -> DR. Logical replication does NOT copy sequences.
#   (default)  : every sequence on DR = exact publisher state (last_value + is_called). Run after each window.
#   --check    : compare only
#   --failover : publisher unreachable; every sequence OWNED by a column becomes max(current, max(column))
#                so new rows can never reuse an id. Unowned sequences keep the last synced value.
# Config     : /etc/odoo-dr/dr.env (or $DR_ENV)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
LOG=$LOG_DIR/dr-seq-sync.log
MODE=sync
for a in "$@"; do case $a in --failover) MODE=failover ;; --check) MODE=check ;; *) echo "unknown option: $a"; exit 2 ;; esac; done
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }

export PGCONNECT_TIMEOUT=15
PUB=(sudo -u postgres psql -X -w -At -v ON_ERROR_STOP=1 "host=$PUB_HOST port=5432 dbname=$DB_NAME user=$REPL_USER sslmode=require")
DR=(sudo -u postgres psql -X -At -v ON_ERROR_STOP=1 -d "$DB_NAME")
# name|last_value|is_called  (pg_sequences.last_value is NULL when never called)
STATE_SQL="select schemaname||'.'||sequencename||'|'||coalesce(last_value, start_value)||'|'||(last_value is not null)::text from pg_sequences where schemaname='public' order by 1"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 755 "$TMP"

compare() {
  "${PUB[@]}" -c "$STATE_SQL" > "$TMP/pub.txt" || { log "ERROR: cannot read publisher sequences"; return 2; }
  "${DR[@]}" -c "$STATE_SQL" > "$TMP/dr.txt"
  local n diff
  n=$(wc -l < "$TMP/pub.txt"); diff=$(diff "$TMP/pub.txt" "$TMP/dr.txt" | grep -c -e '^<')
  log "sequences: publisher=$n DR=$(wc -l < "$TMP/dr.txt") different=$diff"
  [ "$diff" -eq 0 ] && [ "$n" -eq "$(wc -l < "$TMP/dr.txt")" ]
}

case $MODE in
check)
  compare; exit $? ;;
sync)
  log "===== sequence sync (publisher $PUB_HOST)"
  "${PUB[@]}" -c "$STATE_SQL" > "$TMP/pub.txt" || { log "ERROR: cannot read publisher sequences"; exit 1; }
  awk -F'|' '{ printf "SELECT setval(%c%s%c, %s, %s);\n", 39, $1, 39, $2, $3 }' "$TMP/pub.txt" > "$TMP/apply.sql"
  if ! "${DR[@]}" --single-transaction -q -f "$TMP/apply.sql" > /dev/null; then log "ERROR: applying on DR failed (nothing changed)"; exit 1; fi
  if compare; then log "===== sequence sync OK"; exit 0; else log "===== sequence sync FAILED: still different"; exit 1; fi ;;
failover)
  log "===== FAILOVER sequence fix (no publisher): owned sequences -> max(current, max(column))"
  "${DR[@]}" -c "select format('SELECT setval(%L, greatest((select last_value from %s), coalesce((select max(%I) from %s), 0), 1), true);',
       s.oid::regclass::text, s.oid::regclass::text, a.attname, t.oid::regclass::text)
     from pg_class s join pg_depend d on d.objid=s.oid and d.classid='pg_class'::regclass and d.refclassid='pg_class'::regclass and d.deptype in ('a','i')
     join pg_class t on t.oid=d.refobjid join pg_attribute a on a.attrelid=t.oid and a.attnum=d.refobjsubid
     where s.relkind='S'" > "$TMP/failover.sql"
  log "owned sequences: $(wc -l < "$TMP/failover.sql")"
  "${DR[@]}" --single-transaction -q -f "$TMP/failover.sql" > /dev/null && log "===== failover sequence fix OK" || { log "ERROR"; exit 1; }
  log "NOTE: unowned sequences (Odoo ir_sequence_*) keep the last synced values - check document numbering" ;;
esac
