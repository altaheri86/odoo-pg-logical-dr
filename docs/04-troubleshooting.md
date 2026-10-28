# 4. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| First copy of a table fails: *canceling statement due to statement timeout* | `statement_timeout` in the publisher's parameter group | `ALTER ROLE dr_replicator SET statement_timeout = 0;` then `ALTER SUBSCRIPTION … DISABLE / ENABLE`. Workers already inside a COPY keep the old session until it ends — expect one more retry. |
| TCP to the publisher's 5432 times out | Security group allows the wrong IP | `curl -4 https://checkip.amazonaws.com` on DR and allow **that** address (it can differ from the inbound/NAT address) |
| `psql` hangs forever | No connect timeout | `export PGCONNECT_TIMEOUT=15` |
| Window FAILED: *new replication errors* | Someone wrote on DR, or a module added a column | Read the PostgreSQL log. Missing column → module-upgrade runbook. Duplicate key → remove the conflicting DR row, or as a last resort `ALTER SUBSCRIPTION … SKIP (lsn = '<lsn from log>')` (skips that whole transaction). |
| Window WARN: *not caught up* | Big backlog or slow line | Run the window again with `--keep-enabled`; check the line |
| Slot keeps growing, `wal_status` extended / lost | DR not connecting (cron removed, network, errors) | Fix the cause; if `lost`, rebuild from scratch |
| Sequences different | A window failed or was skipped | `dr-seq-sync.sh`, then `--check` |
| Schema restore: *role "dr_replicator" does not exist* | Dump taken after the grants | Filter ACL entries, or dump before creating the role |
| Schema restore: *function unaccent already exists* | Extension installed in `public` on DR, in its own schema on production | Recreate it in the same schema as production |
| First copy much slower than expected | One TCP stream is limited by latency, not by the line | Parallel table sync (4 workers) reached ~1 MB/s where one stream got ~0.43 MB/s |
| Daily sync failed | SSH key, host key, git access | `sudo dr-daily-sync.sh --dry-run` and read the error |
| Odoo on DR answers 502 | Services stopped | Expected until failover |
| SSH to DR refused after an OS upgrade | `ssh.socket` not active | Console: `sudo systemctl enable --now ssh.socket` |
| DR disk filling | Leftover test databases, `pg_wal` | `sudo -u postgres psql -c '\l+'`, drop old copies |

## Working habits that prevented (or caused) problems

- Run long remote jobs with `setsid nohup … > log &`. An interrupted foreground SSH command can **still complete** on the server — always check afterwards.
- Never combine `set -o pipefail` with `| head`, and guard `grep` that may match nothing (`|| true`) under `set -e`.
- `pgrep -f '[n]ame'` — the plain pattern matches the command that runs `pgrep` itself.
- Capture values with `psql -q -At`; without `-q`, command tags like `INSERT 0 1` end up in your variable.
- Cast `"char"` catalog columns (`srsubstate`, `relreplident`) to `::text` before concatenating.
- Copy scripts to the server and run them, instead of long one-liners with nested quotes (especially from PowerShell).
