-- Run on the PUBLISHER (production) as the master user. Read-only.
-- Everything here must be understood BEFORE you create a publication.

-- 1. Must match on the subscriber: owner, encoding, collation, ctype
SELECT datname, pg_get_userbyid(datdba) AS owner, pg_encoding_to_char(encoding) AS enc,
       datlocprovider, datcollate, datctype
  FROM pg_database WHERE datname = current_database();

-- 2. Extensions AND the schema each one lives in (e.g. unaccent is often in its own schema)
SELECT e.extname, e.extversion, n.nspname AS schema
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1;

-- 3. Tables without a primary key: once published, UPDATE/DELETE on them FAILS on production.
--    Must be 0, or give each one REPLICA IDENTITY FULL first.
SELECT c.relname
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
   AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p');

-- 4. Things logical replication never carries (all should be 0 for a simple setup)
SELECT 'unlogged tables'  AS what, count(*) FROM pg_class WHERE relpersistence = 'u' AND relkind = 'r'
UNION ALL SELECT 'materialized views', count(*) FROM pg_matviews
UNION ALL SELECT 'large objects',      count(*) FROM pg_largeobject_metadata;

-- 5. Sizes: table data travels in the first copy, indexes are rebuilt on the subscriber
SELECT pg_size_pretty(sum(pg_table_size(c.oid)))   AS table_data,
       pg_size_pretty(sum(pg_indexes_size(c.oid))) AS indexes,
       count(*)                                    AS tables
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind = 'r';

-- 6. A parameter-group statement_timeout will cancel long first-copy COPYs (see 02-publisher-setup.sql)
SHOW statement_timeout;
SHOW wal_level;            -- must be 'logical' (RDS: rds.logical_replication = 1, then reboot)
