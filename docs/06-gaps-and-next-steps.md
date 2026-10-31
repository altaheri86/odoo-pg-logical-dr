# 6. Gaps and next steps

What separates "replication works" from "we can survive a disaster", with the status after the production rollout:

| # | Gap | Why it matters / status | Priority |
|---|---|---|---|
| 1 | Nightly backup on DR (`pg_dump`, keep 14 days) | Replication is not a backup: a wrong DELETE on production reaches DR within the hour | High |
| 2 | Alerts that reach a person | **Partly done:** every script writes to `ALERTS.log` and syslog, and a web panel shows the verdict. Email via Microsoft 365 Direct Send was rejected because the office IP is on a block list; the Microsoft Graph API (app registration, one mailbox) is the planned fix. Still to add: CloudWatch alarms on `OldestReplicationSlotLag`, `TransactionLogsDiskUsage`, `FreeStorageSpace` | High |
| 3 | User access at failover | Decide DNS (lower the TTL now), port-forwarding, who does it, how long it takes | High |
| 4 | Module upgrades | **Done:** automatic schema sync before every window plus a nightly full schema diff; drift-tested | — |
| 5 | Failback plan and rehearsal | Coming back to the cloud is harder than leaving | High |
| 6 | Certificates on DR | Copies expire — add them to the daily sync | Medium |
| 7 | Failover drill every 3 months | Measures the real RTO and trains the team | Medium |
| 8 | Harden the DR server | Host firewall (SSH, 80/443 and 5432 from the LAN only), VM snapshots, UPS, disk monitoring, security updates (hold the PostgreSQL major) | Medium |
| 9 | Security clean-up | The publisher stays private (tunnel) — done. Next: a dedicated, restricted SSH key for the tunnel (`permitopen` only), deploy keys instead of personal keys | Medium |
| 10 | Tunnel depends on the app server | If the app server is down but RDS is up, no replication (DR keeps the last window). Options: AWS Site-to-Site VPN or SSM port forwarding | Low |
| 11 | Integrations at failover | Mobile/API backends, e-invoicing and outgoing email (SPF / relay for the office IP) | Medium |
| 12 | Contacts and authority | Who declares a disaster, phone list, a printed copy of the runbook | Medium |
| 13 | Continuous replication | RPO in seconds instead of an hour, and less burst load — a one-line change | Low |
