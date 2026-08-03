# Operations guide

For exporter-specific catalogue, command, and retention behavior, see the
[rclone exporter reference](../exporters/rclone.md).

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

The package installs two templates:

- `backmaster@INSTANCE.service` performs a backup attempt;
- `backmaster-health@INSTANCE.service` performs a health check.

Their timers are persistent, so a missed run is started after the host returns.
Inspect the effective schedule and all drop-ins:

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
rclone exporter returns critical when no committed backup exists or the newest
manifest is older than `HEALTHCHECK_MAX_AGE_SECONDS`.

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

## Remote catalogue

For the rclone exporter, only directories containing `manifest.json` count as
completed. List them through the configured instance:

```bash
sudo -u postgres backmaster exporter production-postgres latest-epoch
```

For detailed inspection, load the exporter environment and use rclone directly:

```bash
set -a
source /etc/backmaster/exporters/rclone/production-postgres.env
source /etc/backmaster/secrets/production-postgres-exporter.env
set +a
rclone lsf "$RCLONE_DESTINATION/basebackups" --dirs-only
```

Use direct rclone deletion only during an approved repair. Normal deletion
belongs to exporter retention.

## Retention

Retention runs only after successful publication. The rclone exporter:

1. orders committed manifests newest first;
2. always preserves the newest `MINIMUM_REDUNDANCY` backups;
3. removes additional base backups older than `RETENTION_DAYS`;
4. removes WAL objects older than `WAL_RETENTION_DAYS`.

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
