#!/bin/bash
# Odoo DR - copy schema changes (DDL) publisher -> DR. Logical replication does NOT do this.
# Run by dr-repl-window.sh BEFORE the subscription is enabled, so new columns/tables exist on DR
# before the rows that use them arrive (e.g. after a module install/upgrade on production).
#   automatic : new tables (pg_dump -t from the publisher; the window then runs REFRESH PUBLICATION),
#               new/dropped columns, defaults, NOT NULL, comments, indexes, constraints,
#               free-standing sequences (Odoo ir_sequence_NNN), views
#   alert only: column type changes, tables that exist on DR but not on the publisher
# Reads the publisher's catalog only (no table locks), except pg_dump -t for new tables.
# Needs the dblink extension on DR (postgresql-contrib) - it lives in the helper DB $TOOLS_DB, not in $DB_NAME.
# Usage : sudo dr-schema-sync.sh [--check]
# Exit  : 0 = in sync / applied, 1 = error (publisher unreachable ...), 3 = applied but with alerts (see log)
# Config: /etc/odoo-dr/dr.env (or $DR_ENV)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
PUB_PORT=${PUB_PORT:-5432}; TOOLS=${TOOLS_DB:-dr_tools}; OWNER=${DB_OWNER:-odoo}
ALERTS=${ALERTS:-$LOG_DIR/ALERTS.log}
HERE=$(dirname "$(readlink -f "$0")")
GEN=${SCHEMA_SQL:-$HERE/../sql/05-schema-sync-generator.sql}
LOG=$LOG_DIR/dr-schema-sync.log
REFRESH_FLAG=/run/odoo-dr-refresh-publication
MODE=apply
for a in "$@"; do case $a in --check) MODE=check ;; *) echo "unknown option: $a"; exit 2 ;; esac; done
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }
alert() { log "ALERT: $*"; echo "$(date '+%F %T') schema-sync: $*" >> "$ALERTS"; logger -t odoo-dr -p user.err "schema-sync: $*"; }

export PGCONNECT_TIMEOUT=30
PUBC="host=$PUB_HOST port=$PUB_PORT dbname=$DB_NAME user=$REPL_USER sslmode=require connect_timeout=30 application_name=dr_schema_sync"
PG=(sudo -u postgres psql -X -q -At)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 755 "$TMP"
cp "$GEN" $TMP/gen.sql; chmod 644 $TMP/gen.sql

# one-time: helper database with dblink + a snapshot of the publisher's view definitions
# (PostgreSQL prints some view definitions differently on two servers, so views are compared with this snapshot)
if [ "$("${PG[@]}" -d postgres -c "select count(*) from pg_database where datname='$TOOLS'")" = "0" ]; then
  "${PG[@]}" -d postgres -c "CREATE DATABASE $TOOLS" && log "created database $TOOLS"
fi
"${PG[@]}" -d $TOOLS -c "SET client_min_messages = warning; CREATE EXTENSION IF NOT EXISTS dblink; CREATE TABLE IF NOT EXISTS live_views (v text PRIMARY KEY, md5 text NOT NULL, seen timestamptz DEFAULT now())" \
  || { log "ERROR: cannot prepare $TOOLS"; exit 1; }

log "===== schema sync ($MODE, publisher $PUB_HOST:$PUB_PORT)"
if ! "${PG[@]}" -d $TOOLS -v live="$PUBC" -v dr="dbname=$DB_NAME" -v owner="$OWNER" -f $TMP/gen.sql > $TMP/gen.txt 2> $TMP/gen.err; then
  log "ERROR: cannot compare schemas: $(head -3 $TMP/gen.err)"; exit 1
fi
grep '^#NEWTABLE ' $TMP/gen.txt | cut -d' ' -f2 > $TMP/newtables.txt
grep '^#ALERT ' $TMP/gen.txt | cut -c8- > $TMP/alerts.txt
grep -v '^#' $TMP/gen.txt > $TMP/apply.sql
NT=$(grep -c . $TMP/newtables.txt); NS=$(grep -c ';$' $TMP/apply.sql); NA=$(grep -c . $TMP/alerts.txt)
log "differences: new tables=$NT, statements=$NS, alerts=$NA"
[ "$NT" -gt 0 ] && log "new tables: $(tr '\n' ' ' < $TMP/newtables.txt)"
[ "$NS" -gt 0 ] && sed 's/^/    /' $TMP/apply.sql | head -100
RC=0
while read -r a; do alert "$a"; RC=3; done < $TMP/alerts.txt

snap() {  # replace the snapshot with the publisher's view definitions now (psql variables work in stdin/-f, not -c)
  echo "BEGIN; DELETE FROM live_views; INSERT INTO live_views(v, md5) SELECT v, md5(def) FROM dblink(:'live', 'select viewname, definition from pg_views where schemaname=''public''') AS t(v text, def text); COMMIT;" |
    "${PG[@]}" -d $TOOLS -v ON_ERROR_STOP=1 -v live="$PUBC" > /dev/null
}
# first run: DR's views were restored from the same schema dump, so remember the publisher's current ones
if [ "$("${PG[@]}" -d $TOOLS -c 'select count(*) from live_views')" = "0" ]; then
  snap && log "view snapshot initialised ($("${PG[@]}" -d $TOOLS -c 'select count(*) from live_views') views)"
fi

if [ $MODE = check ]; then
  [ "$NT" -eq 0 ] && [ "$NS" -eq 0 ] && { log "===== IN SYNC"; exit $RC; }
  log "===== NOT IN SYNC (check only, nothing changed)"; exit 1
fi

# new tables: structure (with indexes, constraints, owned sequences, comments) straight from the publisher
if [ "$NT" -gt 0 ]; then
  ARGS=(); while read -r t; do ARGS+=(-t "public.\"$t\""); done < $TMP/newtables.txt
  if sudo -u postgres pg_dump "$PUBC" --schema-only --no-acl --no-publications --no-subscriptions --lock-wait-timeout=10s "${ARGS[@]}" > $TMP/newtables.sql 2> $TMP/dump.err \
     && "${PG[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 --single-transaction -f $TMP/newtables.sql > /dev/null 2> $TMP/restore.err; then
    log "new tables created on DR: $NT"; touch $REFRESH_FLAG
  else
    alert "could not create new tables ($(tr '\n' ' ' < $TMP/newtables.txt)): $(head -2 $TMP/dump.err $TMP/restore.err | tr '\n' ' ')"; RC=3
  fi
fi

# everything else, one statement at a time; a failing statement does not stop the others
if [ "$NS" -gt 0 ]; then
  { echo "SET lock_timeout = '60s';"; cat $TMP/apply.sql; } > $TMP/run.sql
  "${PG[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=0 -f $TMP/run.sql > /dev/null 2> $TMP/run.err
  NE=$(grep -c 'ERROR:' $TMP/run.err)
  # SET NOT NULL on a column whose rows are still empty is expected right after a new column: retried next window
  NNULL=$(grep -c 'contains null values' $TMP/run.err)
  log "applied: $NS statements, errors $NE (of which $NNULL 'NOT NULL waits for data', retried next window)"
  if [ $(( NE - NNULL )) -gt 0 ]; then
    grep 'ERROR:' $TMP/run.err | grep -v 'contains null values' | head -10 | while read -r e; do alert "$e"; done; RC=3
  fi
fi

# remember the publisher's views as applied - only when everything went through, so a failed view is retried
if [ $RC -eq 0 ]; then snap || log "WARN: view snapshot not refreshed"; fi

[ $RC -eq 0 ] && log "===== schema sync OK" || log "===== schema sync done WITH ALERTS (rc=$RC)"
exit $RC
