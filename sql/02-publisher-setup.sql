-- Run on the PUBLISHER as the master user (on RDS: a member of rds_superuser).
-- IMPORTANT: take the schema-only dump (docs/02-build-guide.md, step 7) BEFORE these GRANTs,
-- otherwise the dump carries grants for a role that does not exist on the subscriber.

-- Replication login. Type the password interactively (\password dr_replicator), never on a shell line.
CREATE ROLE dr_replicator WITH LOGIN CONNECTION LIMIT 10;
GRANT rds_replication TO dr_replicator;                -- RDS only; elsewhere: ALTER ROLE ... REPLICATION

GRANT CONNECT ON DATABASE erp TO dr_replicator;
GRANT USAGE ON SCHEMA public TO dr_replicator;
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO dr_replicator;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO dr_replicator;
ALTER DEFAULT PRIVILEGES FOR ROLE odoo IN SCHEMA public GRANT SELECT ON TABLES    TO dr_replicator;
ALTER DEFAULT PRIVILEGES FOR ROLE odoo IN SCHEMA public GRANT SELECT ON SEQUENCES TO dr_replicator;

-- The first copy of each table is ONE long COPY. A server-wide statement_timeout (e.g. 5 min in an
-- RDS parameter group) cancels it and the table retries forever. Lift it for this role only.
ALTER ROLE dr_replicator SET statement_timeout = 0;

-- Publish everything; tables created later (module installs) are included automatically.
CREATE PUBLICATION erp_dr_pub FOR ALL TABLES;

-- Check from the subscriber that the timeout is really gone for replication connections (must print 0):
--   psql "host=<rds-endpoint> dbname=erp user=dr_replicator sslmode=require replication=database" -c "SHOW statement_timeout"
