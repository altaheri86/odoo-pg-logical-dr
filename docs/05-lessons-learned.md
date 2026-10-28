# 5. Lessons learned

The whole setup was first rehearsed against a **duplicate of the production database** (restored from a snapshot, with its own parameter group). Every item below was caught there — none reached production.

| What happened | Lesson |
|---|---|
| A 5-minute `statement_timeout` in the parameter group cancelled the first copy of large tables | The first copy of each table is one long `COPY`. Lift the timeout **for the replication role only** before subscribing. |
| The security group allowed the office's inbound (SSH) IP, but AWS saw a different egress IP | Always check the outgoing address with `checkip`. |
| `unaccent` lived in its own schema on production but in `public` on DR | Compare extension **schemas**, not only names and versions. |
| Schema restore failed on grants for the replication role | Dump the structure **before** granting, or filter ACL entries; restore in one transaction so a failure leaves nothing behind. |
| Sequences were all 0 on DR after the copy | Logical replication never copies sequences. Sync them every window, and raise them past `max(id)` at failover. |
| A shared parameter group would have switched production at its next reboot | Change a **dedicated copy** of the parameter group, never one shared with production. |
| One stream measured 0.43 MB/s; four parallel table syncs reached ~1 MB/s | Measure the line with several streams before estimating copy times. |
| An interrupted command still created a 21 GB database on the server | Long jobs run with `nohup` and a log; after any interruption, check the server state. |
| A status check matched itself and reported "running" | `pgrep -f '[n]ame'`. |

## Design decisions worth repeating

- **Rehearse on a duplicate first.** A database nobody writes to allows an exact, row-by-row comparison — impossible on live.
- **Prove, don't assume.** Row count plus a checksum of every row, for every table.
- **Read-only on production.** Every copy is pulled from the DR side, at the lowest priority and with a bandwidth limit.
- **Replica stays read-only.** Tests run on a `CREATE DATABASE … TEMPLATE` copy with outgoing internet blocked for the Odoo user, crons off and the database neutralized.
- **Pin custom code to what production runs**, not to the branch tip — the branch can be ahead of the deployed code and of the database schema.
