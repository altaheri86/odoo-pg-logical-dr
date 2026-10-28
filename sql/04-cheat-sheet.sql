-- ===== PUBLISHER: the slot (how far behind, how much WAL is kept for DR)
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS behind,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))         AS retained
  FROM pg_replication_slots;
-- wal_status: reserved = fine | extended = above max_wal_size | unreserved/lost = about to / did lose the slot

-- ===== SUBSCRIBER: state and control
SELECT subname, subenabled, subslotname FROM pg_subscription;
ALTER SUBSCRIPTION erp_dr_sub ENABLE;
ALTER SUBSCRIPTION erp_dr_sub DISABLE;
ALTER SUBSCRIPTION erp_dr_sub REFRESH PUBLICATION WITH (copy_data = true);   -- after new tables appear
SELECT pg_stat_reset_subscription_stats(oid) FROM pg_subscription;
-- last resort for a conflicting transaction (skips ALL of it; take the LSN from the PostgreSQL log):
-- ALTER SUBSCRIPTION erp_dr_sub SKIP (lsn = '0/0');

-- ===== FAILOVER: stop replication when the publisher is gone
ALTER SUBSCRIPTION erp_dr_sub DISABLE;
ALTER SUBSCRIPTION erp_dr_sub SET (slot_name = NONE);   -- otherwise DROP waits for the publisher
DROP SUBSCRIPTION erp_dr_sub;

-- ===== TEST COPY on the DR server (never test on the replica itself; needs no connections to it)
-- CREATE DATABASE erp_test WITH TEMPLATE erp OWNER odoo STRATEGY FILE_COPY;
