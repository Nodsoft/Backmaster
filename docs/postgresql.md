# PostgreSQL and Patroni guide

The PostgreSQL driver has two selectable modes:

<!-- markdownlint-disable MD013 -->
| Mode | Produces | Best for | Does not provide |
| --- | --- | --- | --- |
| `physical` | Compressed `pg_basebackup` plus optional continuous WAL | Cluster/member rebuild and PITR | Per-database selection |
| `logical` | Globals plus one custom-format `pg_dump` per database | Selective backup, migration, object/database restore | PITR or a Patroni member image |
<!-- markdownlint-enable MD013 -->

`physical` remains the default. Use separate Backmaster instances and remote
destination roots if you want both modes: for example `postgres-physical` and
`postgres-logical`. This gives each flow independent freshness, naming,
retention, monitoring, and restore history.

## 1. Prepare PostgreSQL

The backup role must be able to connect to PostgreSQL. Physical mode requires
replication access for `pg_basebackup`. Logical mode requires `CONNECT` plus
enough privileges to read every selected object; a superuser-equivalent backup
role is simplest but should be protected accordingly. When using the local
`postgres` OS account with peer authentication, the supplied systemd drop-ins
need no password file.

For a dedicated database role, grant `REPLICATION`, allow the connection in
`pg_hba.conf`, and store credentials in a protected driver secret file or a
PostgreSQL-supported credential mechanism. Test the exact service identity.

A standby can take a physical base backup when PostgreSQL is configured for it
and the required WAL is available. Logical dumps can also run against a standby,
but long dumps may conflict with recovery and query cancellation settings. For
fleet fallback, point each node to its local member port (for example Patroni on
`5431`) and test the complete workload there rather than using HAProxy.

## 2. Create the files

Create an instance file, driver file, exporter file, and exporter secret as
described in [Configuration](configuration.md). Start from the packaged examples:

```bash
driver_docs=/usr/share/doc/backmaster-driver-postgres/examples
exporter_docs=/usr/share/doc/backmaster-exporter-rclone/examples

sudo install -m 0644 \
  "$driver_docs/config/instances/nsys-postgres.env.example" \
  /etc/backmaster/instances.d/production-postgres.env
sudo install -m 0644 \
  "$driver_docs/config/drivers/postgres.env.example" \
  /etc/backmaster/drivers/postgres/production-postgres.env
sudo install -m 0644 \
  "$exporter_docs/config/exporters/rclone.env.example" \
  /etc/backmaster/exporters/rclone/production-postgres.env
sudo install -m 0640 -o root -g postgres \
  "$exporter_docs/config/exporters/rclone.secrets.env.example" \
  /etc/backmaster/secrets/production-postgres-exporter.env
```

Edit all four files. Ensure `INSTANCE_NAME=production-postgres` matches the
instance filename and `NODE_NAME` is correct on each machine. In the driver
file, select `PG_BACKUP_MODE=physical` or `PG_BACKUP_MODE=logical`. Logical mode
accepts exact newline-delimited filters:

```bash
PG_BACKUP_MODE=logical
PGDATABASE=postgres
PG_DATABASE_INCLUDE=$'backmaster\nmatrix\nsynapse'
PG_DATABASE_EXCLUDE=$'scratch\ntest'
```

An empty include list selects every connectable non-template database.
Exclusions take precedence. Backmaster always includes `globals.sql.gz` for
roles and tablespaces, even when database filtering is used.

## 3. Install the service identity drop-ins

The generic service runs as `backmaster`; PostgreSQL normally runs as
`postgres`. Create drop-ins for both backup and health units:

```bash
backup_dropin=/etc/systemd/system/\
backmaster@production-postgres.service.d/driver.conf
health_dropin=/etc/systemd/system/\
backmaster-health@production-postgres.service.d/driver.conf

sudo install -d -m 0755 \
  /etc/systemd/system/backmaster@production-postgres.service.d \
  /etc/systemd/system/backmaster-health@production-postgres.service.d

sudo tee "$backup_dropin" >/dev/null <<'EOF'
[Unit]
After=patroni.service

[Service]
User=postgres
Group=postgres
EOF

sudo tee "$health_dropin" >/dev/null <<'EOF'
[Service]
User=postgres
Group=postgres
EOF

sudo systemctl daemon-reload
```

On non-Patroni systems, replace `patroni.service` with the appropriate local
PostgreSQL unit or omit that ordering line.

## 4. Enable continuous WAL archival (physical mode only)

Skip this section for logical instances. Logical dumps neither require nor use
WAL archival, and the driver rejects `wal-archive` and `wal-restore` when
`PG_BACKUP_MODE=logical`.

In Patroni configuration:

```yaml
postgresql:
  parameters:
    archive_mode: "on"
    archive_timeout: 60s
    archive_command: >-
      /usr/bin/backmaster driver production-postgres wal-archive %p
```

Apply the Patroni configuration using your normal controlled process. Verify
the effective PostgreSQL settings and force a WAL switch:

```sql
SHOW archive_mode;
SHOW archive_command;
SELECT pg_switch_wal();
```

Then confirm `pg_stat_archiver` advances and a compressed object appears under
`RCLONE_DESTINATION/objects/wal/`. A successful daily base backup does not prove
that continuous WAL archival works.

## 5. Validate before scheduling

Run the checks as the same Unix user as systemd:

```bash
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster health production-postgres
sudo -u postgres backmaster run production-postgres --force
```

The first `health` may report no completed export; that is expected before the
first successful backup. After `run`, inspect the journal and remote manifest:

```bash
journalctl -u backmaster@production-postgres.service -n 100 --no-pager
sudo -u postgres backmaster exporter production-postgres latest-epoch
```

Run `backmaster health production-postgres` again. Then complete the
[restore runbook](postgres-restore.md) on an isolated host.

For logical mode, inspect `payload/databases.json` in the exported backup. It is
the authoritative map from original database names to safe dump filenames.

## 6. Schedule one node

Create a timer override with the desired UTC schedule:

```bash
sudo systemctl edit backmaster@production-postgres.timer
```

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:15:00 UTC
Persistent=true
RandomizedDelaySec=5m
```

Enable backup and health timers:

```bash
sudo systemctl enable --now \
  backmaster@production-postgres.timer \
  backmaster-health@production-postgres.timer
systemctl list-timers 'backmaster*'
```

## 7. Configure preferred/fallback nodes

On every node:

- install the same package versions;
- use the same instance name and exporter destination;
- use the same Consul lock key and freshness threshold;
- point the driver at that node's local PostgreSQL member;
- use a distinct `NODE_NAME` and, if desired, custom backup-name suffix.

Schedule the preferred node first and the fallback after enough time for a
normal base backup to finish. With `MAX_AGE_SECONDS=82800`, a completed preferred
backup remains fresh during the fallback window; the fallback logs
`reason=fresh_backup_exists` and exits.

Example:

| Node | Attempt | Role |
| --- | --- | --- |
| Axon | 02:15 UTC | Preferred producer |
| Myelin | 03:15 UTC | Produces only if no fresh completed export exists |

The shared Consul lock handles overlap, but the fallback delay should still be
longer than the expected preferred backup duration. Test fallback by preventing
the preferred attempt, not by disabling Consul.

## PostgreSQL-specific sizing

Local peak usage is approximately one complete staged backup plus metadata. A
failed export intentionally keeps the `.ready` stage, so reserve capacity for
that stage until publication can resume.

Physical network use includes the base backup and continuous WAL; CPU use
depends on `PG_COMPRESSION`. Logical dumps run sequentially, so each database is
transactionally consistent on its own, but the set is not one cluster-wide
snapshot. CPU and size depend on `PG_LOGICAL_COMPRESSION`. Measure source load,
backup duration, staging space, and restore speed for the chosen mode.
