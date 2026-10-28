-- Run on the SUBSCRIBER (DR server) as postgres, after the schema has been restored.
-- No password in the connection string: libpq reads it from ~postgres/.pgpass
--   <rds-endpoint>:5432:*:dr_replicator:<password>      (file mode 600, owner postgres)

CREATE SUBSCRIPTION erp_dr_sub
  CONNECTION 'host=<rds-endpoint> port=5432 dbname=erp user=dr_replicator sslmode=require connect_timeout=15 application_name=erp_dr_sub keepalives_idle=60'
  PUBLICATION erp_dr_pub
  WITH (copy_data = true, create_slot = true, slot_name = 'erp_dr_slot', enabled = true);

-- Watch the first copy:  i = waiting, d = copying, f/s = catching up, r = ready
SELECT srsubstate::text, count(*) FROM pg_subscription_rel GROUP BY 1;
SELECT relid::regclass, pg_size_pretty(bytes_processed) FROM pg_stat_progress_copy;
SELECT * FROM pg_stat_subscription_stats;      -- a few retries are normal, a rising count is not
