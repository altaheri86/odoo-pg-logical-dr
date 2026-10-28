# 6. Gaps and next steps

What separates "replication works" from "we can survive a disaster":

| # | Gap | Why it matters | Priority |
|---|---|---|---|
| 1 | Nightly backup on DR (`pg_dump`, keep 14 days) | Replication is not a backup: a wrong DELETE on production reaches DR within the hour | High |
| 2 | Alerts | Nobody reads logs at night. Notify on failed windows / syncs; CloudWatch alarms on `OldestReplicationSlotLag`, `TransactionLogsDiskUsage`, `FreeStorageSpace` (e.g. alert when kept WAL > 5 GB) | High |
| 3 | User access at failover | Decide DNS (lower the TTL now), port-forwarding, who does it, how long it takes | High |
| 4 | Module-upgrade procedure rehearsal | The first real upgrade will otherwise stop replication | High |
| 5 | Failback plan and rehearsal | Coming back to the cloud is harder than leaving | High |
| 6 | Certificates on DR | Copies expire — add them to the daily sync | Medium |
| 7 | Failover drill every 3 months | Measures the real RTO and trains the team | Medium |
| 8 | Harden the DR server | Host firewall (SSH, 80/443 and 5432 from the LAN only), VM snapshots, UPS, disk monitoring, security updates (hold the PostgreSQL major) | Medium |
| 9 | Security clean-up | Dedicated security group for the database, consider a VPN instead of a public endpoint, deploy keys instead of personal keys | Medium |
| 10 | Integrations at failover | Mobile/API backends, e-invoicing and outgoing email (SPF / relay for the office IP) | Medium |
| 11 | Contacts and authority | Who declares a disaster, phone list, a printed copy of the runbook | Medium |
| 12 | Continuous replication | RPO in seconds instead of an hour, and less burst load — a one-line change | Low |
