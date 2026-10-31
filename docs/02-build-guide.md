# 2. Build guide

Every step was run in the real build. Values in `<angle brackets>` are placeholders; the rest of the names match `config/dr.env.example`.

**Markers:** `[DR]` run on the DR server · `[PROD]` production app server, **read-only** · `[RDS]` psql against the publisher · `[PC]` admin workstation (AWS CLI).

> Passwords live only in `~/.pgpass` files (mode 600). Never type them on a shell command line or put them in scripts.

---

## Step 1 — Prepare the DR server

The DR server must match production (here Ubuntu 24.04, Python 3.12).

```bash
# [DR] full update, then the release upgrade detached so an SSH drop cannot kill it
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
sudo setsid nohup do-release-upgrade -f DistUpgradeViewNonInteractive > /tmp/upgrade.log 2>&1 &
sudo tail -f /var/log/dist-upgrade/main.log      # wait for "confirmRestart()", then:
sudo reboot
```

> Ubuntu 24.04 moves SSH to socket activation during the upgrade; the port can stay closed until the reboot. From the console: `sudo systemctl enable --now ssh.socket`.

## Step 2 — PostgreSQL on DR

Same **major** version as the publisher. A newer minor is fine. Install only the versioned package, never the `postgresql` meta-package, so apt never jumps a major version.

```bash
# [DR]
sudo apt-get install -y postgresql-common ca-certificates curl
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
sudo apt-get install -y postgresql-17 postgresql-client-17 postgresql-17-pgvector
sudo cp config/postgresql-dr.conf /etc/postgresql/17/main/conf.d/10-odoo-dr.conf
cat config/pg_hba-dr.conf | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
sudo systemctl restart postgresql@17-main
sudo -u postgres psql -c "select count(*) from pg_hba_file_rules where error is not null"   # 0
```

## Step 3 — The empty database

Run `sql/01-publisher-prechecks.sql` on the publisher first. The DR database must match **owner, encoding, collation, ctype and extension schemas**.

```bash
# [DR]  (example: collate C, ctype en_US.UTF-8, unaccent in its own schema)
sudo -u postgres psql -c "CREATE ROLE odoo LOGIN CREATEDB;"
sudo -u postgres psql -c "\password odoo"
sudo -u postgres psql -c "CREATE DATABASE erp OWNER odoo TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc LC_COLLATE 'C' LC_CTYPE 'en_US.UTF-8';"
sudo -u postgres psql -d erp <<'EOF'
CREATE SCHEMA unaccent_schema AUTHORIZATION odoo;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION unaccent WITH SCHEMA unaccent_schema;
CREATE EXTENSION vector;
EOF
```

## Step 4 — Copy the Odoo application (read-only on production)

All copies are **pulled from DR**. On production rsync only reads, at `nice 19` / `ionice idle`, with a bandwidth limit, and is resumable.

```bash
# [DR] same service user and paths as production
sudo useradd -m -s /bin/bash odoo && sudo passwd -l odoo
SSH="ssh -p <ssh-port> -i ~/.ssh/id_ed25519 -o BatchMode=yes"
sudo rsync -rlpt --partial --delay-updates --compress --compress-choice=zstd \
  --bwlimit=300 --rsync-path="nice -n 19 ionice -c3 rsync" -e "$SSH" --chown=odoo:odoo \
  --exclude=__pycache__/ <prod-user>@<app-host>:/opt/odoo18/addons-enterprise/ /opt/odoo18/addons-enterprise/
# filestore: same command, NO --delete
```

- **Odoo core:** copy it from production with `rsync --checksum --delete` rather than a fresh git clone — production installs often have local changes or moved folders.
- **Custom modules:** `git clone` the branch, then check out the exact commit production deployed.
- **Python venv:** production ARM → DR x86, so rebuild it with the **exact** `pip freeze` from production. To keep downloads light: `pip install --dry-run --report r.json -r requirements.txt`, download the URLs with `curl --limit-rate`, then `pip install --no-index --find-links=<wheelhouse>`. Building `pycairo` needs `patchelf` and `ninja-build` from apt.
- **wkhtmltopdf:** the same version as production (0.12.6.1 with patched Qt).
- **Configs:** copy them; on DR change only `db_host = localhost` (and the DR DB password). Keep the original as a root-only backup.
- **Services:** copy the systemd units but **do not enable them** — Odoo must not write to the replica.
- **nginx:** copy the sites and certificates; add `config/nginx-dr-ip-access.conf` until DNS exists. A 502 is expected while Odoo is stopped.

## Step 5 — Prepare the publisher

> ⚠️ This touches production. `rds.logical_replication` is static: **one reboot (a few minutes)**. If the parameter group is shared with other instances, they will switch at their next reboot too — use a dedicated copy of the group.

```bash
# [PC]
aws rds modify-db-parameter-group --db-parameter-group-name <param-group> \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" \
               "ParameterName=max_slot_wal_keep_size,ParameterValue=61440,ApplyMethod=immediate"
aws rds reboot-db-instance --db-instance-identifier <instance>
```

### Reaching the publisher

Check first: `aws rds describe-db-instances --query "DBInstances[0].PubliclyAccessible"`.

**Private RDS (recommended, what production used):** do not make it public. Tunnel through the production app server, which already reaches RDS inside the VPC. Nothing is installed or changed there; it only relays the TLS stream.

```bash
# [DR] config/dr-pg-tunnel.service -> forwards 127.0.0.1:15432 to <rds-endpoint>:5432 over SSH
sudo cp config/dr-pg-tunnel.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now dr-pg-tunnel
timeout 10 bash -c '</dev/tcp/127.0.0.1/15432' && echo open
# from now on every connection to the publisher: host=127.0.0.1 port=15432 sslmode=require
```

**Public RDS (the rehearsal duplicate):** allow the DR server's **outgoing** address on 5432 in the security group, and set `PUB_HOST=<rds-endpoint>`, `PUB_PORT=5432`, `TUNNEL_UNIT=` in `dr.env`.

```bash
# [DR] what AWS sees as your address (can differ from the inbound/NAT address)
curl -4 https://checkip.amazonaws.com
timeout 10 bash -c '</dev/tcp/<rds-endpoint>/5432' && echo open
```

The rest of this guide uses the tunnel (`127.0.0.1:15432`).

## Step 6 — Copy the schema

Logical replication carries data, not structure. **Dump before creating the replication grants.**

```bash
# [DR]
PGOPTIONS="-c statement_timeout=0" pg_dump -w -h 127.0.0.1 -p 15432 -U <master> -d erp --schema-only -Fc \
  --no-publications --no-subscriptions --lock-wait-timeout=60s -f live.dump
pg_restore -l live.dump > live.list
# drop grants (ACL) and objects DR already has (schema unaccent_schema, extensions)
grep -v -e '^;' live.list | grep -v -e ' ACL ' \
  | grep -v -E ' SCHEMA - unaccent_schema | (EXTENSION|COMMENT - EXTENSION) ' > restore.list
{ pg_restore -L restore.list -f - live.dump
  echo 'REVOKE USAGE ON SCHEMA public FROM PUBLIC;'; echo 'GRANT ALL ON SCHEMA public TO PUBLIC;'   # production's own ACL
} | sudo -u postgres psql -q -d erp -v ON_ERROR_STOP=1 --single-transaction
# compare: identical except the ARRAY print style PostgreSQL uses in re-created views
```

## Step 7 — Replication user and publication

Run `sql/02-publisher-setup.sql`. Then put the replication password in **both** `~/.pgpass` of your admin user **and** `~postgres/.pgpass` — the subscription workers run as the OS user `postgres`.

```
127.0.0.1:15432:*:dr_replicator:<password>
```

## Step 8 — Subscription (first copy)

Run `sql/03-subscriber-setup.sql` at a quiet time. Watch with `scripts/dr-repl-status.sh` until every table is `r`. In production, ~13 GB of table data took 4 h 40 min at ~1 MB/s through the tunnel; users noticed nothing.

> **Freeze module deploys on production during the first copy.** In production, a module upgrade 2 hours into the copy added 3 columns. The apply worker stopped with *missing replicated column* until the columns were added on DR (17 minutes, no data lost). After step 10 the hourly schema sync handles this by itself.

## Step 9 — Verify

```bash
sudo bash scripts/dr-verify-data.sh     # waits for lag 0, re-hashes busy tables -> RESULT: ALL n TABLES IDENTICAL
sudo scripts/dr-seq-sync.sh             # copy sequences, verified against the copied values
```

Production result: 1,306 of 1,306 tables and 62.4 M rows identical. Pass 1 found 3 busy tables changing while they were hashed; pass 2 after catch-up found 0.

## Step 10 — Automate

```bash
sudo scripts/dr-schema-sync.sh --check  # creates the helper DB (dblink) and the view snapshot -> IN SYNC
sudo scripts/dr-repl-window.sh          # one manual window -> "window OK"
sudo scripts/dr-schema-diff.sh          # full schema comparison -> IDENTICAL
sudo crontab -e                         # add the lines from config/crontab.example
sudo cp config/logrotate-odoo-dr /etc/logrotate.d/odoo-dr
```

The window is now: **schema sync → enable → catch up (all tables ready) → sequences → disable**, every hour.
