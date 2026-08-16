# PostgreSQL restore draft

The PostgreSQL flow is physical disaster recovery: Barman Cloud base backups
plus continuous WAL. It restores the entire PostgreSQL 18 cluster and supports
point-in-time recovery.

Before production sign-off, prove all of these on an isolated host:

- a completed backup initiated by Axon;
- a completed backup initiated by Myelin while it is a standby;
- Axon failure followed by Myelin fallback;
- a latest restore;
- a point-in-time restore between two known transactions;
- measured local temporary disk use;
- alerting for stale base backup and failed WAL archiving.

List the catalogue:

```bash
sudo -u postgres backmaster connectivity nsys-postgres

set -a
source /etc/backmaster/drivers/postgres/nsys-postgres.env
source /etc/backmaster/secrets/nsys-postgres.env
set +a

barman-cloud-backup-list \
  --cloud-provider azure-blob-storage \
  "$AZURE_DESTINATION" "$BARMAN_SERVER_NAME"
```

Restore into an empty, isolated PostgreSQL data directory:

```bash
barman-cloud-restore \
  --cloud-provider azure-blob-storage \
  "$AZURE_DESTINATION" \
  "$BARMAN_SERVER_NAME" \
  latest \
  /var/lib/postgresql/18/restore-test
```

Configure the Backmaster `wal-restore` command as PostgreSQL's
`restore_command`, create `recovery.signal`, and start PostgreSQL on an isolated
port. For a total Patroni loss, recover one authoritative node first; form the
new cluster around it, then let Patroni clone all replicas from that recovered
primary. Never start two independently restored copies as peers.

