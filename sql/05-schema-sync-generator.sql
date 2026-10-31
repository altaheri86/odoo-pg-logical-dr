-- Odoo DR - schema sync generator (run by scripts/dr-schema-sync.sh in the DR helper database, which has dblink).
-- Compares the publisher schema (public) with the DR database and prints, one per row:
--   '#NEWTABLE <name>'  tables to copy from the publisher with pg_dump (done by the shell script)
--   '#ALERT <text>'     changes not applied automatically
--   SQL statements      to run on the DR database, already in a safe order
-- psql variables: :'live' = conninfo of the publisher, :'dr' = conninfo of the DR database, :'owner' = database owner role
\set ON_ERROR_STOP 1
CREATE TEMP TABLE lc AS SELECT * FROM dblink(:'live', $q$
  select c.relname, a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, pg_get_expr(d.adbin,d.adrelid), col_description(c.oid,a.attnum)
  from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace
  left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where n.nspname='public' and c.relkind in ('r','p') and a.attnum>0 and not a.attisdropped $q$)
  AS t(tbl text, col text, typ text, nn bool, def text, cmt text);
CREATE TEMP TABLE dc AS SELECT * FROM dblink(:'dr', $q$
  select c.relname, a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, pg_get_expr(d.adbin,d.adrelid), col_description(c.oid,a.attnum)
  from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace
  left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where n.nspname='public' and c.relkind in ('r','p') and a.attnum>0 and not a.attisdropped $q$)
  AS t(tbl text, col text, typ text, nn bool, def text, cmt text);
-- constraints (no NOT NULL here; those are columns.nn)
CREATE TEMP TABLE lk AS SELECT * FROM dblink(:'live', $q$
  select c.relname, k.conname, k.contype::text, pg_get_constraintdef(k.oid), coalesce(i.relname,'')
  from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace
  left join pg_class i on i.oid=k.conindid
  where n.nspname='public' and k.contype in ('p','u','f','c','x') $q$) AS t(tbl text, con text, typ text, def text, idx text);
CREATE TEMP TABLE dk AS SELECT * FROM dblink(:'dr', $q$
  select c.relname, k.conname, k.contype::text, pg_get_constraintdef(k.oid), coalesce(i.relname,'')
  from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace
  left join pg_class i on i.oid=k.conindid
  where n.nspname='public' and k.contype in ('p','u','f','c','x') $q$) AS t(tbl text, con text, typ text, def text, idx text);
CREATE TEMP TABLE li AS SELECT * FROM dblink(:'live', $q$ select tablename, indexname, indexdef from pg_indexes where schemaname='public' $q$) AS t(tbl text, idx text, def text);
CREATE TEMP TABLE di AS SELECT * FROM dblink(:'dr',   $q$ select tablename, indexname, indexdef from pg_indexes where schemaname='public' $q$) AS t(tbl text, idx text, def text);
-- sequences; owned = belongs to a table column (comes and goes with its table)
CREATE TEMP TABLE ls AS SELECT * FROM dblink(:'live', $q$
  select s.sequencename, format_type(c.seqtypid,null), c.seqincrement, c.seqmin, c.seqmax, c.seqstart, c.seqcache, c.seqcycle,
         exists(select 1 from pg_depend d where d.objid=sc.oid and d.classid='pg_class'::regclass and d.refclassid='pg_class'::regclass and d.deptype in ('a','i'))
  from pg_sequences s join pg_class sc on sc.relname=s.sequencename join pg_namespace n on n.oid=sc.relnamespace and n.nspname=s.schemaname
  join pg_sequence c on c.seqrelid=sc.oid where s.schemaname='public' $q$)
  AS t(seq text, typ text, inc bigint, mn bigint, mx bigint, st bigint, cache bigint, cyc bool, owned bool);
CREATE TEMP TABLE ds AS SELECT * FROM dblink(:'dr', $q$
  select s.sequencename, exists(select 1 from pg_depend d where d.objid=sc.oid and d.classid='pg_class'::regclass and d.refclassid='pg_class'::regclass and d.deptype in ('a','i'))
  from pg_sequences s join pg_class sc on sc.relname=s.sequencename join pg_namespace n on n.oid=sc.relnamespace and n.nspname=s.schemaname
  where s.schemaname='public' $q$) AS t(seq text, owned bool);
CREATE TEMP TABLE lv AS SELECT * FROM dblink(:'live', $q$ select viewname, definition from pg_views where schemaname='public' $q$) AS t(v text, def text);
CREATE TEMP TABLE dv AS SELECT * FROM dblink(:'dr',   $q$ select viewname from pg_views where schemaname='public' $q$) AS t(v text);

CREATE TEMP VIEW both_t AS SELECT DISTINCT tbl FROM lc WHERE tbl IN (SELECT tbl FROM dc);

SELECT s FROM (
  -- 10 new tables
  SELECT 10 o, tbl k, '#NEWTABLE '||tbl s FROM (SELECT DISTINCT tbl FROM lc EXCEPT SELECT DISTINCT tbl FROM dc) x
  UNION ALL
  -- 11 tables gone on live: keep on DR, alert (never drop data automatically)
  SELECT 11, tbl, '#ALERT table exists on DR but not on live: '||tbl FROM (SELECT DISTINCT tbl FROM dc EXCEPT SELECT DISTINCT tbl FROM lc) x
  UNION ALL
  -- 20 constraints missing or changed on live -> drop on DR first (FKs first)
  SELECT CASE WHEN d.typ='f' THEN 20 ELSE 21 END, d.tbl||'.'||d.con, format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I;', d.tbl, d.con)
  FROM dk d LEFT JOIN lk l ON l.tbl=d.tbl AND l.con=d.con
  WHERE d.tbl IN (SELECT tbl FROM both_t) AND (l.con IS NULL OR l.def<>d.def)
  UNION ALL
  -- 25 plain indexes on DR that live does not have (or with another definition)
  SELECT 25, d.idx, format('DROP INDEX IF EXISTS public.%I;', d.idx)
  FROM di d LEFT JOIN li l ON l.idx=d.idx
  WHERE d.tbl IN (SELECT tbl FROM both_t) AND d.idx NOT IN (SELECT idx FROM dk WHERE idx<>'')
    AND (l.idx IS NULL OR l.def<>d.def)
  UNION ALL
  -- 26 views dropped on live
  SELECT 26, v, format('DROP VIEW IF EXISTS public.%I;', v) FROM (SELECT v FROM dv EXCEPT SELECT v FROM lv) x
  UNION ALL
  -- 30 new columns (nullable first; NOT NULL is set in 41 once the data is there)
  SELECT 30, l.tbl||'.'||l.col, format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS %I %s%s;', l.tbl, l.col, l.typ, coalesce(' DEFAULT '||l.def,''))
  FROM lc l LEFT JOIN dc d ON d.tbl=l.tbl AND d.col=l.col
  WHERE l.tbl IN (SELECT tbl FROM both_t) AND d.col IS NULL
  UNION ALL
  -- 31 column comments new or changed
  SELECT 31, l.tbl||'.'||l.col, format('COMMENT ON COLUMN public.%I.%I IS %s;', l.tbl, l.col, coalesce(quote_literal(l.cmt),'NULL'))
  FROM lc l LEFT JOIN dc d ON d.tbl=l.tbl AND d.col=l.col
  WHERE l.tbl IN (SELECT tbl FROM both_t) AND l.cmt IS DISTINCT FROM d.cmt
  UNION ALL
  -- 35 columns dropped on live
  SELECT 35, d.tbl||'.'||d.col, format('ALTER TABLE public.%I DROP COLUMN IF EXISTS %I;', d.tbl, d.col)
  FROM dc d LEFT JOIN lc l ON l.tbl=d.tbl AND l.col=d.col
  WHERE d.tbl IN (SELECT tbl FROM both_t) AND l.col IS NULL
  UNION ALL
  -- 40 default changed
  SELECT 40, l.tbl||'.'||l.col, format('ALTER TABLE public.%I ALTER COLUMN %I %s;', l.tbl, l.col, CASE WHEN l.def IS NULL THEN 'DROP DEFAULT' ELSE 'SET DEFAULT '||l.def END)
  FROM lc l JOIN dc d ON d.tbl=l.tbl AND d.col=l.col WHERE l.def IS DISTINCT FROM d.def
  UNION ALL
  -- 41 NOT NULL changed (also new NOT NULL columns: SET NOT NULL fails while rows are still NULL -> retried next window)
  SELECT 41, l.tbl||'.'||l.col, format('ALTER TABLE public.%I ALTER COLUMN %I %s NOT NULL;', l.tbl, l.col, CASE WHEN l.nn THEN 'SET' ELSE 'DROP' END)
  FROM lc l LEFT JOIN dc d ON d.tbl=l.tbl AND d.col=l.col
  WHERE l.tbl IN (SELECT tbl FROM both_t) AND ((d.col IS NULL AND l.nn) OR (d.col IS NOT NULL AND l.nn<>d.nn))
  UNION ALL
  -- 45 type changed: alert only
  SELECT 45, l.tbl||'.'||l.col, '#ALERT column type differs '||l.tbl||'.'||l.col||': live '||l.typ||', DR '||d.typ
  FROM lc l JOIN dc d ON d.tbl=l.tbl AND d.col=l.col WHERE l.typ<>d.typ
  UNION ALL
  -- 50 sequences missing on DR (Odoo creates ir_sequence_NNN for new journals/documents)
  SELECT 50, l.seq, format('CREATE SEQUENCE IF NOT EXISTS public.%I AS %s INCREMENT %s MINVALUE %s MAXVALUE %s START %s CACHE %s %s; ALTER SEQUENCE public.%I OWNER TO %I;',
                            l.seq, l.typ, l.inc, l.mn, l.mx, l.st, l.cache, CASE WHEN l.cyc THEN 'CYCLE' ELSE 'NO CYCLE' END, l.seq, :'owner')
  FROM ls l WHERE NOT l.owned AND l.seq NOT IN (SELECT seq FROM ds)
  UNION ALL
  -- 51 free-standing sequences removed on live
  SELECT 51, d.seq, format('DROP SEQUENCE IF EXISTS public.%I;', d.seq) FROM ds d WHERE NOT d.owned AND d.seq NOT IN (SELECT seq FROM ls)
  UNION ALL
  -- 60 indexes missing on DR (not the ones created by constraints)
  SELECT 60, l.idx, l.def||';'
  FROM li l LEFT JOIN di d ON d.idx=l.idx
  WHERE l.tbl IN (SELECT tbl FROM both_t) AND l.idx NOT IN (SELECT idx FROM lk WHERE idx<>'')
    AND (d.idx IS NULL OR l.def<>d.def)
  UNION ALL
  -- 70 constraints missing on DR (FKs last)
  SELECT CASE WHEN l.typ='f' THEN 71 ELSE 70 END, l.tbl||'.'||l.con, format('ALTER TABLE public.%I ADD CONSTRAINT %I %s;', l.tbl, l.con, l.def)
  FROM lk l LEFT JOIN dk d ON d.tbl=l.tbl AND d.con=l.con
  WHERE l.tbl IN (SELECT tbl FROM both_t) AND (d.con IS NULL OR l.def<>d.def)
  UNION ALL
  -- 80 views new on live, or changed since the last snapshot (only when a snapshot exists)
  SELECT 80, l.v, format('DROP VIEW IF EXISTS public.%I; CREATE VIEW public.%I AS %s; ALTER VIEW public.%I OWNER TO %I;', l.v, l.v, rtrim(l.def, E'; \n'), l.v, :'owner')
  FROM lv l LEFT JOIN live_views s ON s.v=l.v
  WHERE EXISTS (SELECT 1 FROM live_views)
    AND (l.v NOT IN (SELECT v FROM dv) OR s.md5 IS DISTINCT FROM md5(l.def))
) x ORDER BY o, k;
