#!/bin/bash
# Odoo DR - compare EVERY table publisher vs DR: row count + order-independent hash of every row.
# Hash = sum of the first 64 bits of md5(row::text). Both sessions use TimeZone=UTC so dates print the same.
# Run it when the publisher has no writes (a test copy), or right after a window at a quiet time.
# Usage : bash dr-verify-data.sh            Output: ./verify-<timestamp>/
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
export PGCONNECT_TIMEOUT=15 PGOPTIONS='-c TimeZone=UTC -c statement_timeout=0 -c extra_float_digits=1'
O=./verify-$(date +%Y%m%d-%H%M); mkdir -p "$O"
PUB=(sudo -u postgres --preserve-env=PGOPTIONS,PGCONNECT_TIMEOUT psql -X -w -At "-F|" "host=$PUB_HOST port=5432 dbname=$DB_NAME user=$REPL_USER sslmode=require")
SUB=(sudo -u postgres --preserve-env=PGOPTIONS psql -X -d "$DB_NAME" -At "-F|")

"${PUB[@]}" -c "select quote_ident(c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' order by pg_total_relation_size(c.oid) desc" > "$O/tables.txt"
echo "tables: $(wc -l < "$O/tables.txt")"
while read -r t; do
  echo "select '$t', count(*), coalesce(sum(('x'||substr(md5(r::text),1,16))::bit(64)::bigint::numeric),0) from public.$t r;"
done < "$O/tables.txt" > "$O/queries.sql"
chmod 644 "$O/queries.sql"

start=$(date +%s)
# queries go in on stdin, so the postgres user never needs to read this folder
( "${PUB[@]}" < "$O/queries.sql" > "$O/pub.txt" 2> "$O/pub.err" ) &
( "${SUB[@]}" < "$O/queries.sql" > "$O/sub.txt" 2> "$O/sub.err" ) &
wait
echo "hashing took $(( $(date +%s)-start )) s"
sort "$O/pub.txt" > "$O/pub.s"; sort "$O/sub.txt" > "$O/sub.s"
echo "rows: publisher $(awk -F'|' '{s+=$2} END {print s}' "$O/pub.s")  DR $(awk -F'|' '{s+=$2} END {print s}' "$O/sub.s")"
echo "errors: publisher=$(wc -l < "$O/pub.err") DR=$(wc -l < "$O/sub.err")"
if diff -q "$O/pub.s" "$O/sub.s" > /dev/null && [ "$(wc -l < "$O/pub.s")" = "$(wc -l < "$O/tables.txt")" ]; then
  echo "RESULT: ALL $(wc -l < "$O/pub.s") TABLES IDENTICAL (row count + row hash)"
else
  echo "RESULT: DIFFERENCES"; diff "$O/pub.s" "$O/sub.s" | head -40
fi
