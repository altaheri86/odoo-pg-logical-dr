#!/bin/bash
# Odoo DR - compare EVERY table publisher vs DR: row count + order-independent hash of every row.
# Hash = sum of the first 64 bits of md5(row::text). Both sessions use TimeZone=UTC so dates print the same.
# Works on a live publisher: it waits until DR has caught up, hashes everything, then re-hashes only the
# tables that differed (up to 3 more passes) - busy tables change while they are being hashed.
# Run it with the subscription ENABLED (a window with --keep-enabled, or during the first copy's catch-up).
# Usage : sudo bash dr-verify-data.sh            Output: ./verify-<timestamp>/
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
PUB_PORT=${PUB_PORT:-5432}
export PGCONNECT_TIMEOUT=30 PGOPTIONS='-c TimeZone=UTC -c statement_timeout=0 -c extra_float_digits=1'
O=./verify-$(date +%Y%m%d-%H%M); mkdir -p "$O"
PUB=(sudo -u postgres --preserve-env=PGOPTIONS,PGCONNECT_TIMEOUT psql -X -w -At "-F|" "host=$PUB_HOST port=$PUB_PORT dbname=$DB_NAME user=$REPL_USER sslmode=require")
SUB=(sudo -u postgres --preserve-env=PGOPTIONS psql -X -d "$DB_NAME" -At "-F|")

"${PUB[@]}" -c "select quote_ident(c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' order by pg_total_relation_size(c.oid) desc" > "$O/tables.txt"
N=$(wc -l < "$O/tables.txt"); echo "tables: $N"
# a check that compares nothing must fail, not report "ALL 0 TABLES IDENTICAL"
[ "$N" -gt 0 ] || { echo "RESULT: FAILED - cannot read the table list from the publisher"; exit 1; }

gen() { while read -r t; do
  echo "select '$t', count(*), coalesce(sum(('x'||substr(md5(r::text),1,16))::bit(64)::bigint::numeric),0) from public.$t r;"
done < "$1"; }
lag() { "${PUB[@]}" -c "select pg_current_wal_flush_lsn()-confirmed_flush_lsn from pg_replication_slots where slot_name='$SLOT_NAME'"; }
wait_caught_up() { for i in $(seq 1 60); do [ "$(lag)" -le 0 ] 2>/dev/null && return 0; sleep 5; done; return 1; }

hash_pass() {  # $1 = table list file, $2 = pass name
  gen "$1" > "$O/$2.sql"; chmod 644 "$O/$2.sql"
  # queries go in on stdin, so the postgres user never needs to read this folder
  ( "${PUB[@]}" < "$O/$2.sql" > "$O/$2-pub.txt" 2> "$O/$2-pub.err" ) &
  ( "${SUB[@]}" < "$O/$2.sql" > "$O/$2-sub.txt" 2> "$O/$2-sub.err" ) &
  wait
  sort "$O/$2-pub.txt" > "$O/$2-pub.s"; sort "$O/$2-sub.txt" > "$O/$2-sub.s"
  { diff "$O/$2-pub.s" "$O/$2-sub.s" | grep '^[<>]' | cut -c3- | cut -d'|' -f1; } | sort -u > "$O/$2-diff.txt"
  echo "$(date +%T) $2: hashed publisher=$(wc -l < "$O/$2-pub.s") DR=$(wc -l < "$O/$2-sub.s") tables, errors publisher=$(wc -l < "$O/$2-pub.err") DR=$(wc -l < "$O/$2-sub.err"), different=$(wc -l < "$O/$2-diff.txt")"
}

start=$(date +%s)
wait_caught_up && echo "DR caught up (lag 0) before pass 1"
hash_pass "$O/tables.txt" p1
echo "pass 1 took $(( $(date +%s)-start )) s; rows publisher=$(awk -F'|' '{s+=$2} END {print s}' "$O/p1-pub.s") DR=$(awk -F'|' '{s+=$2} END {print s}' "$O/p1-sub.s")"
cp "$O/p1-diff.txt" "$O/left.txt"
for p in 2 3 4; do
  [ -s "$O/left.txt" ] || break
  sleep 20; wait_caught_up && echo "DR caught up (lag 0) before pass $p"
  hash_pass "$O/left.txt" p$p; cp "$O/p$p-diff.txt" "$O/left.txt"
done
if [ ! -s "$O/left.txt" ] && [ "$(wc -l < "$O/p1-pub.s")" = "$N" ] && [ "$(wc -l < "$O/p1-sub.s")" = "$N" ]; then
  echo "RESULT: ALL $N TABLES IDENTICAL (row count + row hash)"
else
  echo "RESULT: $(wc -l < "$O/left.txt") TABLE(S) STILL DIFFERENT:"
  while read -r t; do echo "  $t  publisher: $(cat "$O"/p*-pub.s | grep "^$t|" | tail -1 | cut -d'|' -f2-)  DR: $(cat "$O"/p*-sub.s | grep "^$t|" | tail -1 | cut -d'|' -f2-)"; done < "$O/left.txt"
fi
echo "total $(( $(date +%s)-start )) s, output in $O"
