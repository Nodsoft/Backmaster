# Troubleshooting

Start with the effective service definition, recent journal, and the two direct
checks:

```bash
systemctl cat backmaster@production-postgres.service
journalctl -u backmaster@production-postgres.service -n 200 --no-pager
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster health production-postgres
```

## Configuration errors

### `missing_instance_config`

The requested instance needs a readable file at
`/etc/backmaster/instances.d/INSTANCE.env`. Instance names may contain only
lowercase letters, digits, and hyphens.

### `instance_name_mismatch`

`INSTANCE_NAME` inside the file does not match its filename. Keep both identical.

### `missing_driver` or `missing_exporter`

The named component is not installed, is the wrong version, or `DRIVER` /
`EXPORTER` is misspelled. Verify package versions and executable paths:

```bash
dpkg-query -W 'backmaster*'
find /usr/lib/backmaster -maxdepth 3 -type f -executable -print
```

### Cannot read a policy or secret file

Run `namei -l PATH` and verify every parent directory is traversable by the
service user. PostgreSQL examples use `root:postgres` mode `0640` for secrets.

## Consul and locking

### Lock timeout or no run starts

Verify `consul members`, agent health, ACL permissions for the lock key, and
network reachability. Every fallback node must use the same lock key. Do not use
`--force` to work around a broken lock; it does not and should not bypass it.

### Preferred and fallback both create backups

Check that they use the same destination, lock key, and freshness threshold.
Confirm clocks are synchronized. Distinct destination roots create distinct
catalogues and cannot suppress each other.

## PostgreSQL driver

### `local PostgreSQL is unavailable`

Run the exact readiness check as the service user:

```bash
sudo -u postgres pg_isready \
  -h /var/run/postgresql -p 5431 -U postgres
```

Check that `PGPORT` points to the local member, socket permissions allow access,
and PostgreSQL/Patroni is running.

### `pg_basebackup` authentication or permission failure (physical)

Test `pg_basebackup` manually with the configured host, port, and role. Confirm
the database role has replication permission and `pg_hba.conf` allows the
connection. Avoid silently switching the backup to a load-balanced endpoint.

### `included database does not exist or cannot be dumped` (logical)

Every non-empty line in `PG_DATABASE_INCLUDE` must exactly match a connectable,
non-template database. Check the effective configuration and list databases as
the service user. Backmaster fails rather than silently omitting a requested
database.

### `database filters selected no databases` (logical)

The include/exclude combination removed every database. Exclusions take
precedence over includes. Correct the exact-name lists; do not treat a
globals-only stage as a complete logical database backup.

### `pg_dump` or `pg_dumpall` permission failure (logical)

Test the failing client command as the systemd service identity. The database
role needs `CONNECT` and enough privileges to read every selected object.
`pg_dumpall --globals-only` also needs access to cluster-wide role and
tablespace metadata. Confirm that every required extension exists on the
restore target during a drill.

### WAL archive failures

WAL commands are available only when `PG_BACKUP_MODE=physical`. Do not configure
Patroni `archive_command` to use a logical Backmaster instance.

Inspect PostgreSQL:

```sql
SELECT * FROM pg_stat_archiver;
```

Then invoke the archive path on a disposable copy of a WAL file if your
operating procedure permits it. Check exporter connectivity, staging space, and
the `archive_command` path. The Debian package installs `/usr/bin/backmaster`.

## Rclone exporter

See the [rclone exporter reference](../exporters/rclone.md) for its complete
configuration, remote layout, commands, and retention model.

### Connectivity fails

Run the check as the service user and verify the remote name embedded in
`RCLONE_DESTINATION` matches the `RCLONE_CONFIG_<NAME>_*` environment variables.
Azure remote `azure:` uses the uppercase prefix `RCLONE_CONFIG_AZURE_`.

Confirm credentials permit list, read, write, and delete only in the intended
container/path.

### Health says there is no completed backup

The catalogue found no valid `manifest.json`. The first backup may not have run,
publication may have failed before its commit marker, or the configured
destination may be wrong. Inspect local `.ready` stages before modifying remote
objects.

### Export failed but files exist remotely

Payload without a manifest is intentionally incomplete. Keep the local `.ready`
stage and rerun after fixing connectivity. The exporter will republish and write
the manifest last.

## Disk space

Check the stage filesystem:

```bash
df -h /var/lib/backmaster
sudo du -sh /var/lib/backmaster/*
```

A `.ready` directory is recoverable work and should normally be resumed. A stale
`.partial.*` directory came from interrupted driver production. Before removing
one, confirm the service is stopped and no Backmaster or `pg_basebackup` process
uses it.

## A backup is skipped unexpectedly

The exporter reported a completed manifest younger than `MAX_AGE_SECONDS`.
Review `latest_backup_epoch` and `age_seconds` in the journal. Use `--force` only
when an additional backup is intentional.

## Collect a diagnostic bundle

Do not include secret contents. Useful output is:

```bash
backmaster --version
dpkg-query -W 'backmaster*' 'rclone' 'postgresql-client*'
systemctl cat backmaster@production-postgres.service
systemctl cat backmaster@production-postgres.timer
journalctl -u backmaster@production-postgres.service -n 200 --no-pager
consul members
timedatectl status
```

Redact account names, destinations, hostnames, and tokens according to your
incident-sharing policy.
