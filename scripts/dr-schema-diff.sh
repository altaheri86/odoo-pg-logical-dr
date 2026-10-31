#!/bin/bash
# Odoo DR - nightly FULL schema comparison publisher vs DR (safety net for the hourly dr-schema-sync.sh).
# Compares the complete pg_dump --schema-only text (functions, triggers, views, everything), ignoring only
# what is known to differ harmlessly: ACLs, extensions, \restrict tokens and PostgreSQL's cast print style in views.
# Read-only on both sides. pg_dump takes ACCESS SHARE locks on the publisher's tables (~2 min) -> run at night.
# Usage : sudo dr-schema-diff.sh
# Output: $LOG_DIR/schema-diff/<date>.diff (kept 30 days)
# Exit  : 0 identical, 1 error, 3 differences (also written to $ALERTS + syslog)
# Config: /etc/odoo-dr/dr.env (or $DR_ENV). Extra lines to ignore: DIFF_IGNORE='regex' (e.g. an extension schema)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
PUB_PORT=${PUB_PORT:-5432}; ALERTS=${ALERTS:-$LOG_DIR/ALERTS.log}; DIFF_IGNORE=${DIFF_IGNORE:-^$}
LOG=$LOG_DIR/dr-schema-diff.log
OUT=$LOG_DIR/schema-diff
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 777 "$TMP"
PUBC="host=$PUB_HOST port=$PUB_PORT dbname=$DB_NAME user=$REPL_USER sslmode=require connect_timeout=30 application_name=dr_schema_diff"
DUMP=(--schema-only --no-acl --no-publications --no-subscriptions)

log "===== full schema diff (publisher $PUB_HOST:$PUB_PORT)"
sudo -u postgres env PGOPTIONS='-c statement_timeout=0' pg_dump "$PUBC" "${DUMP[@]}" --lock-wait-timeout=60s -f $TMP/pub.sql 2> $TMP/err \
  || { log "ERROR: pg_dump publisher failed: $(head -2 $TMP/err)"; exit 1; }
sudo -u postgres pg_dump -d "$DB_NAME" "${DUMP[@]}" -f $TMP/dr.sql || { log "ERROR: pg_dump DR failed"; exit 1; }
# normalise: comments, blank lines, extensions, \restrict tokens, and the two cast styles PostgreSQL prints differently
n() { grep -vE '^--|^$|EXTENSION|^\\(un)?restrict ' "$1" | grep -vE "$DIFF_IGNORE" |
      sed -E 's/\(\(ARRAY\[([^]]*)\]\)::text\[\]\)/(ARRAY[\1])/g; s/\(([^()]*)::character varying\)::text/\1::character varying/g'; }
n $TMP/pub.sql > $TMP/p; n $TMP/dr.sql > $TMP/d
F=$OUT/$(date +%F).diff
diff $TMP/p $TMP/d > $F; N=$(grep -c '^[<>]' $F)
find "$OUT" -name '*.diff' -mtime +30 -delete
log "publisher $(wc -l < $TMP/pub.sql) lines, DR $(wc -l < $TMP/dr.sql) lines, different lines: $N"
if [ "$N" -eq 0 ]; then rm -f $F; log "===== IDENTICAL"; exit 0; fi
head -20 $F
echo "$(date '+%F %T') schema-diff: publisher and DR schemas differ ($N lines) - see $F" >> "$ALERTS"
logger -t odoo-dr -p user.err "schema-diff: publisher and DR schemas differ ($N lines) - see $F"
log "===== DIFFERENT ($N lines) - see $F"; exit 3
