# Operations guide

For exporter-specific catalogue, command, and retention behavior, see the
[rclone](../exporters/rclone.md) or [AzCopy](../exporters/azcopy.md) reference.

## Commands

| Command | Use |
| --- | --- |
| `backmaster connectivity INSTANCE` | Test source and exporter access |
| `backmaster run INSTANCE` | Run only if the remote completed backup is stale |
| `backmaster run INSTANCE --force` | Run regardless of remote freshness |
| `backmaster health INSTANCE` | Check source readiness and remote backup age |
| `backmaster driver INSTANCE VERB …` | Invoke a driver verb |
| `backmaster exporter INSTANCE VERB …` | Invoke an exporter verb |
| `backmaster --version` | Report installed core version |

`--force` is appropriate for commissioning and controlled tests. It still
acquires the Consul lock and resumes an existing ready stage before creating a
new backup.

## Scheduling with systemd

The package installs reusable backup and health service templates plus an
hourly health timer. It deliberately does not install a backup timer because
backup cadence is deployment-specific:

- `backmaster@INSTANCE.service` performs a backup attempt;
- `backmaster-health@INSTANCE.service` performs a health check;
- `backmaster-health@INSTANCE.timer` triggers the health check hourly.

Create and enable an instance-specific `backmaster@INSTANCE.timer` only after a
manual service run and restore test succeed. The complete
[systemd units and timers guide](systemd.md) covers service identities,
PostgreSQL drop-ins, timer creation, calendar overrides, persistent catch-up,
fleet fallback, sandbox paths, verification, and troubleshooting.

Inspect the effective units and schedules:

```bash
systemctl cat backmaster@production-postgres.service
systemctl cat backmaster@production-postgres.timer
systemctl list-timers 'backmaster*'
```

Trigger an immediate service run through systemd:

```bash
sudo systemctl start backmaster@production-postgres.service
systemctl status backmaster@production-postgres.service
```

## Direct CLI runs

Prefer starting the service for backup runs. `StateDirectory=backmaster/%i`
creates `/var/lib/backmaster/INSTANCE` for the unit's effective user; a direct
`sudo -u postgres backmaster run …` bypasses that systemd setup.

If a direct invocation is required, create the default state path first:

```bash
sudo install -d -o root -g root -m 0755 /var/lib/backmaster
sudo install -d -o postgres -g postgres -m 0750 \
  /var/lib/backmaster/production-postgres
sudo -u postgres backmaster run production-postgres --force
```

For a custom `STAGING_ROOT`, substitute its configured path. The instance
directory must be writable by the account running Backmaster and should not be
writable by unrelated users. Backmaster now stops before invoking the driver if
the parent cannot be created or written; it reports the failing path instead of
continuing with an invalid `/payload` path.

## Logs

The core emits key-value logs containing the instance and node. Follow a run:

```bash
journalctl -fu backmaster@production-postgres.service
```

Review the current boot and health checks:

```bash
journalctl -b \
  -u backmaster@production-postgres.service \
  -u backmaster-health@production-postgres.service
```

Important successful events include `prepare_complete`, `export_complete`, and
`retention_complete`. `result=skipped reason=fresh_backup_exists` is a healthy
fallback outcome, not a failure.

## Health monitoring

`backmaster health` succeeds only when both the driver and exporter health
checks succeed. The PostgreSQL driver checks the local client and server. The
exporter returns critical when no committed backup exists or the newest manifest
is older than `HEALTHCHECK_MAX_AGE_SECONDS`.

The packaged health timer runs hourly. A oneshot unit's failure is visible to
systemd and the journal, but production deployments should route it into the
existing monitoring/alerting system. Also alert on:

- failed backup service units;
- PostgreSQL `pg_stat_archiver.failed_count` or stale `last_archived_time`;
- staging filesystem space;
- Consul health and clock synchronization;
- object-store authentication and capacity/billing anomalies.

## Staging and resume

Normal state leaves no backup stage after a successful export. During creation,
a hidden `.partial.*` directory exists. After sealing, the stage is named
`BACKUP_NAME.ready`.

```bash
sudo find /var/lib/backmaster/production-postgres \
  -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
```

If publication fails, do not delete a `.ready` stage. Fix destination access and
run the instance again; Backmaster publishes that stage before considering a new
backup. A `.partial.*` directory indicates interrupted production and is not
automatically resumed. Investigate the cause and remove it only after confirming
that no Backmaster process owns it.

Archive layouts need enough local staging capacity for the unbundled driver
payload and the completed archive at the same time. Backmaster deletes the
unbundled copy only after archive creation succeeds, and deletes the ready stage
only after the exporter successfully publishes the manifest. Monitor free
space, CPU time, and backup duration when increasing compression levels.

## Remote catalogue

For both bundled exporters, only directories containing `manifest.json` count
as completed. Query the catalogue through the configured instance:

```bash
sudo -u postgres backmaster exporter production-postgres latest-epoch
```

Use the selected exporter's component reference for direct storage inspection.
Avoid direct deletion during routine operation; deletion belongs to exporter
retention.

For example, an rclone deployment can list backup directories with:

```bash
set -a
source /etc/backmaster/exporters/rclone/production-postgres.env
source /etc/backmaster/secrets/production-postgres-exporter.env
set +a
rclone lsf "$RCLONE_DESTINATION/basebackups" --dirs-only
```

## Retention

Retention runs only after successful publication. Both bundled exporters do
the following:

1. orders committed manifests newest first;
2. protects the newest `MINIMUM_REDUNDANCY` committed backups by count;
3. removes additional base backups older than `RETENTION_DAYS`;
4. removes WAL objects older than `WAL_RETENTION_DAYS`.

The minimum-redundancy value is not a storage replica setting. It is a safety
floor within one instance destination: `2` means that age-based cleanup cannot
remove the newest two committed backups, even if both exceed the age limit. It
does not protect WAL. A value of `0` removes that count guard.

Use `unlimited` (or `none`) instead of a day count to disable base-backup or WAL
cleanup independently. If `RETENTION_DAYS=unlimited`, the minimum-redundancy
setting is unused. Numeric `0` remains an immediate zero-day threshold.

Before shortening retention, confirm that the oldest base backup you intend to
restore still has its required WAL range. Object-store versioning or immutability
is complementary protection against operator error and credential compromise.

## Upgrades

Upgrade core, driver, and exporter packages together:

```bash
sudo apt update
sudo apt install --only-upgrade \
  backmaster-core \
  backmaster-driver-postgres \
  backmaster-exporter-rclone
```

Replace the exporter package with `backmaster-exporter-azcopy` on AzCopy
instances.

Then verify:

```bash
backmaster --version
sudo systemctl daemon-reload
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster health production-postgres
```

Configuration below `/etc/backmaster` is administrator-owned. Review release
notes and packaged examples before adopting new settings.

## Routine restore drills

At least on every material PostgreSQL or storage change—and regularly
thereafter—restore the newest backup to an isolated host, verify checksums,
start PostgreSQL on a non-production port, and run application-level checks.
Periodically test a timestamped PITR and a backup created by each fallback node.
Record restore duration against the recovery-time objective.
