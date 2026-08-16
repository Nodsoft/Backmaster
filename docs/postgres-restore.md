# PostgreSQL restore draft

The PostgreSQL flow produces a compressed tar-format `pg_basebackup` plus a
Backmaster checksum file and manifest. Streamed WAL makes each base backup
self-contained; separately archived WAL enables point-in-time recovery.

Before production sign-off, prove backups from Axon and Myelin, fallback after
Axon failure, latest restore, point-in-time restore, staging disk bounds, stale
backup alerting, and failed WAL-archive alerting on an isolated host.

## Fetch and verify

Load the exporter configuration and list committed manifests. A backup without
`manifest.json` is incomplete and must not be restored.

```bash
set -a
source /etc/backmaster/exporters/rclone/nsys-postgres.env
source /etc/backmaster/secrets/nsys-postgres-exporter.env
set +a

rclone lsf "$RCLONE_DESTINATION/basebackups" --dirs-only
rclone copy \
  "$RCLONE_DESTINATION/basebackups/REPLACE_BACKUP_NAME" \
  /var/tmp/backmaster-restore

cd /var/tmp/backmaster-restore
sha256sum --check checksums.sha256
```

## Restore the base backup

Extract `base.tar.*` into an empty PostgreSQL data directory. Extract each
tablespace archive at the location described by `tablespace_map`. Extract
`pg_wal.tar.*` into `pg_wal` when present. Preserve PostgreSQL ownership and
permissions.

For PITR, configure PostgreSQL's `restore_command` to call:

```bash
backmaster driver nsys-postgres wal-restore %f %p
```

Create `recovery.signal`, set the desired recovery target, and start PostgreSQL
on an isolated port. For a total Patroni loss, recover one authoritative node
first, form the new cluster around it, and let Patroni clone replicas from that
node. Never start two independently restored copies as peers.
