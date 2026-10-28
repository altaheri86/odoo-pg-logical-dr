# 3. Operations and runbooks

## Daily checks

| Check | Command (DR) | Healthy |
|---|---|---|
| Replication windows | `sudo tail -n 12 /var/log/odoo-dr/dr-repl-window.log` | `window OK` every hour |
| Morning file sync | `sudo tail -n 15 /var/log/odoo-dr/dr-daily-sync.log` | `daily sync OK` |
| Replication state | `sudo scripts/dr-repl-status.sh` | all tables ready, errors not rising, `enabled=false` between windows |
| Sequences | `sudo scripts/dr-seq-sync.sh --check` | `different=0` |
| Slot on publisher | `sql/04-cheat-sheet.sql` (slot query) | `wal_status = reserved`, retained < ~1 GB |

> **Never write to the DR database while replication runs.** It does not change production, but edits are silently overwritten, inserts cause duplicate-key errors that **stop** replication, and deletes leave DR missing data. Test on a copy (below).

---

## Runbook: failover

![Failover](../diagrams/diagram-failover.png)

1. **Declare.** The decision owner confirms the cloud site is down and accepts losing up to the last hour.
2. **Stop the sync.** Remove the hourly cron line, then detach and drop the subscription.
3. **Fix the IDs.** `sudo scripts/dr-seq-sync.sh --failover` raises every owned sequence above the highest existing ID (works without the publisher).
4. **Integrations.** Point external integrations (e.g. a mobile backend URL stored in a table) at their DR endpoints.
5. **Start Odoo.** Enable and start the services, check the logs.
6. **Switch users.** DNS / port-forward 80/443 to the DR server.

```bash
sudo -u postgres psql -d erp -c "ALTER SUBSCRIPTION erp_dr_sub DISABLE;"
sudo -u postgres psql -d erp -c "ALTER SUBSCRIPTION erp_dr_sub SET (slot_name = NONE);"   # publisher unreachable
sudo -u postgres psql -d erp -c "DROP SUBSCRIPTION erp_dr_sub;"
sudo scripts/dr-seq-sync.sh --failover
sudo systemctl enable --now odoo18 && sudo tail -f /var/log/odoo/odoo18.log
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8069/web/login      # 200
```

After failover **the DR server is production**: back it up at once and every night, and plan the failback. Watch integrations that may repeat work done in the lost hour (e-invoicing submissions, emails).

### Failback (design and rehearse)

- Freeze DR Odoo, `pg_dump -Fc` the DR database and restore it to a new cloud instance — or replicate DR → cloud with the same method in reverse.
- rsync the filestore back, switch DNS, then rebuild DR replication from scratch.

---

## Runbook: module install / upgrade on production

Module upgrades add tables and columns; logical replication does not copy structure. No data is lost while you fix it — the slot keeps every change.

**Symptom when forgotten:** the next window logs `new replication errors`; the PostgreSQL log says the target relation *is missing replicated column*.

1. Before the deploy, get the list of changed modules. (Watch out for services started with `-u <modules>` — they upgrade on every restart.)
2. After the deploy, dump the schema again (build guide step 6) and diff it against DR.
3. Apply only the differences on DR: new tables via `pg_dump -s -t <table>`, new columns via `ALTER TABLE … ADD COLUMN …`.
4. `ALTER SUBSCRIPTION erp_dr_sub REFRESH PUBLICATION WITH (copy_data = true);`
5. Run a window by hand, check `window OK`, diff the schema again.

**Safer order for added columns:** adding a column on DR **first** is harmless. Get the new structure from a test server, apply it on DR, then upgrade production.

---

## Runbook: test Odoo on DR with a copy

Never start Odoo on the replica. Copy it between two windows, run Odoo on the copy with internet blocked, delete it.

```bash
sudo flock /run/lock/odoo-dr-repl-window.lock \
  sudo -u postgres psql -c 'CREATE DATABASE erp_test WITH TEMPLATE erp OWNER odoo STRATEGY FILE_COPY'
F=/opt/odoo18/.local/share/Odoo/filestore; sudo cp -al $F/erp $F/erp_test         # hard links, no extra space
sudo iptables -A OUTPUT -m owner --uid-owner odoo ! -d 127.0.0.0/8 -j REJECT       # no email, no APIs
# test config: db_name=erp_test, dbfilter=^erp_test$, workers=0, max_cron_threads=0
sudo -u odoo /opt/odoo18/venv/bin/python3.12 /opt/odoo18/odoo-bin neutralize -c /etc/odoo-test.conf -d erp_test
# ... test, then clean up
sudo iptables -D OUTPUT -m owner --uid-owner odoo ! -d 127.0.0.0/8 -j REJECT
sudo -u postgres psql -c 'DROP DATABASE erp_test'; sudo rm -rf $F/erp_test
```

---

## Runbook: rebuild replication from scratch

When the slot is lost (`wal_status = lost`), after a long outage, or after failback:

```bash
# remove the hourly cron line first
sudo -u postgres psql -d erp -c "DROP SUBSCRIPTION IF EXISTS erp_dr_sub;"     # also drops the slot on the publisher
sudo -u postgres psql -c 'DROP DATABASE erp'
# then build guide steps 3, 6, 8, 9, 10
```

## Runbook: rotate passwords

| Password | Change on | Then update |
|---|---|---|
| DR database owner | DR: `\password odoo` | `db_password` in the Odoo configs on DR |
| `dr_replicator` | publisher: `\password dr_replicator` | both `.pgpass` files on DR |
| Publisher master | cloud console | admin `.pgpass` on DR |

## Runbook: certificates

Certificates renew on production; DR holds a copy. Refresh it before expiry (or add it to the daily sync), then `sudo nginx -t && sudo systemctl reload nginx`.
