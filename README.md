# Odoo 18 Disaster Recovery with PostgreSQL Logical Replication

**From Amazon RDS (PostgreSQL 17) to an on-premise server — built, rehearsed on a duplicate RDS, and verified row by row.**

![Architecture](diagrams/diagram-architecture.png)

## The problem

A company runs its Odoo 18 ERP on AWS: the application on EC2 (ARM / Graviton) and the database on Amazon RDS for PostgreSQL 17 (24 GB). If AWS becomes unavailable, the business must keep working from its own office server:

| Target | Value |
|---|---|
| Max data loss (RPO), database | ≤ 1 hour |
| Max data loss, attachments & modules | ≤ 24 hours |
| Time to be back (RTO) | ≈ 1 hour |
| Constraint | **No changes on the production app server** — read-only access only |
| Constraint | Office internet line ≈ 1 MB/s |

## Why logical replication

| Option | Verdict |
|---|---|
| Streaming (physical) replica | Not possible: RDS does not ship physical WAL to servers outside AWS, and the CPU architectures differ (ARM → x86) |
| `pg_dump` every few hours | Moves the full database every time, long restores, fragile on internet drops, RPO of hours |
| **Logical replication** ✅ | Only changed rows travel, works across CPU types, resumes after outages from a replication slot |

Logical replication does **not** copy sequences or schema changes — this project closes both gaps (an hourly sequence sync and a module-upgrade procedure).

![Replication](diagrams/diagram-replication.png)

## What was built

- **DR server**: Ubuntu 24.04, PostgreSQL 17 subscriber, the Odoo 18 application installed at the same paths as production (services stopped until failover), nginx and certificates.
- **Database**: `FOR ALL TABLES` publication on RDS → subscription on DR, opened in an **hourly window** by cron (enable → catch up → sync 1,900+ sequences → disable).
- **Files**: daily `rsync` of Odoo core, enterprise addons and filestore (read-only on production, low priority, bandwidth-limited, resumable) and `git` sync of custom modules pinned to **the commit production actually runs**.
- **Verification**: a script that compares **every table** on both sides — row count plus an order-independent checksum of every row.
- **Runbooks**: failover, module upgrades, test copies, rebuild, password and certificate rotation.

## Results (rehearsal on a duplicate RDS)

| Check | Result |
|---|---|
| Tables replicated | **1,292 / 1,292** |
| Rows verified identical (count + row hash) | **61.7 million** on both sides |
| First copy | ~12 GB of table data in ~5 h at ~1 MB/s, 4 tables in parallel |
| Load on RDS during the first copy | **5–7 % CPU**, memory flat |
| INSERT / UPDATE / DELETE latency (window open) | ~0.1 s |
| Changes made while DR was disconnected | all applied in the next window, sequences matched |

## Lessons learned (the interesting part)

1. **`statement_timeout` in the RDS parameter group killed the first copy.** Each table's initial copy is one long `COPY`; a 5-minute limit cancelled it and the big tables would have retried forever. Fix: `ALTER ROLE dr_replicator SET statement_timeout = 0` — the replication role only.
2. **The office's inbound and outbound public IPs were different.** The security group allowed the SSH IP; AWS saw a different egress IP. Always check with `curl https://checkip.amazonaws.com`.
3. **An extension lived in its own schema** (`unaccent` in `unaccent_schema`, plus a `public.unaccent()` wrapper used by indexes). Compare extension *schemas*, not just names.
4. **Dump the schema before creating replication grants**, or the restore fails on a role that only exists on the publisher.
5. **Sequences are never replicated** — without a sync, Odoo on DR would reuse existing IDs after failover.
6. **Never write to the replica.** Edits are silently overwritten, inserts cause duplicate keys that stop replication. Test on a `CREATE DATABASE … TEMPLATE` copy instead.
7. **The replication slot keeps WAL on the publisher** while DR is offline (here ~768 MB/hour because RDS forces a WAL switch every 5 minutes). `max_slot_wal_keep_size` caps it so production disk is safe.

More in [docs/05-lessons-learned.md](docs/05-lessons-learned.md).

## Repository layout

```
README.md
docs/
  01-architecture.md        design, concepts, inventory template
  02-build-guide.md         step by step, every command
  03-operations-runbooks.md daily checks, failover, module upgrades, test copy, rebuild
  04-troubleshooting.md     symptom → cause → fix
  05-lessons-learned.md
  06-gaps-and-next-steps.md what a production-grade DR still needs
scripts/
  dr-repl-window.sh         hourly replication window (cron)
  dr-seq-sync.sh            sequence sync, --check, --failover
  dr-daily-sync.sh          files + modules + git (cron)
  dr-repl-status.sh         status at a glance
  dr-verify-data.sh         table-by-table verification
sql/                        publisher pre-checks, publisher setup, subscriber setup, cheat sheet
config/                     dr.env.example, PostgreSQL tuning, pg_hba, nginx, logrotate, crontab
diagrams/
```

## Quick start

1. Read [docs/01-architecture.md](docs/01-architecture.md), then follow [docs/02-build-guide.md](docs/02-build-guide.md).
2. Copy `config/dr.env.example` to `/etc/odoo-dr/dr.env` (root, mode 600) and fill in your values.
3. Install the scripts to `/opt/odoo-dr/scripts/` and the cron lines from `config/crontab.example`.
4. Passwords live only in `~/.pgpass` files (mode 600) — never in this repo, in scripts or on command lines.

## Tech

PostgreSQL 17 logical replication · Amazon RDS · Odoo 18 · Ubuntu 24.04 · Bash · rsync · cron · nginx · AWS CLI

## Disclaimer

Based on a real production project. All company names, hostnames, IP addresses, ports, account IDs and credentials have been replaced with placeholders. Test everything on a copy before touching production.

## Author

**Mohamed Alshaibani**, Senior DevOps Engineer: [github.com/altaheri86](https://github.com/altaheri86)

## License

[MIT](LICENSE)
