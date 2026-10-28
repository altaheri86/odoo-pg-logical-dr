#!/bin/bash
# Odoo DR - logical replication status at a glance. Read-only.
# Usage: sudo dr-repl-status.sh
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
P="sudo -u postgres psql -X -At -d $DB_NAME"
date '+%F %T'
echo "== subscription"
$P -c "select subname||'  enabled='||subenabled::text||'  slot='||subslotname from pg_subscription"
echo "== tables: i=init d=copying f=finished s=synced r=ready"
$P -c "select string_agg(st||'='||n, '  ' order by st) from (select srsubstate::text st, count(*) n from pg_subscription_rel group by 1) x"
$P -c "select 'ready '||count(*) filter (where srsubstate='r')||' of '||count(*)||' tables ('||round(100.0*count(*) filter (where srsubstate='r')/greatest(count(*),1),1)||'%)' from pg_subscription_rel"
echo "== copying now"
$P -c "select '  '||c.relid::regclass::text||'  '||pg_size_pretty(c.bytes_processed)||'  rows='||c.tuples_processed from pg_stat_progress_copy c order by c.bytes_processed desc"
echo "== database size on DR"
$P -c "select '  '||pg_size_pretty(pg_database_size(current_database()))"
echo "== apply worker"
$P -c "select '  received='||coalesce(received_lsn::text,'-')||'  last msg='||coalesce(to_char(last_msg_receipt_time,'HH24:MI:SS'),'-') from pg_stat_subscription where relid is null"
echo "== errors"
$P -c "select '  apply_errors='||apply_error_count||'  sync_errors='||sync_error_count from pg_stat_subscription_stats"
