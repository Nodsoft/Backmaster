# PostgreSQL and Patroni guide

The PostgreSQL driver produces a physical, compressed `pg_basebackup`. Streamed
WAL makes the base backup self-contained, while separately archived WAL enables
point-in-time recovery (PITR).

This flow backs up the whole PostgreSQL cluster, not individual databases. It is
suited to rebuilding a failed member or recovering an entire Patroni cluster.
Logical dumps may be added as a separate future driver when object-level restore
is more important than cluster recovery.

## 1. Prepare PostgreSQL

The backup role must be able to connect to the direct PostgreSQL member and run
`pg_basebackup`. When using the local `postgres` OS account with peer
authentication, the supplied systemd drop-ins need no password file.

For a dedicated database role, grant `REPLICATION`, allow the connection in
`pg_hba.conf`, and store credentials in a protected driver secret file or a
PostgreSQL-supported credential mechanism. Test the exact service identity.

A standby can take a base backup when PostgreSQL is configured for it and the
required WAL is available. Backmaster therefore points to the local member port
(for example Patroni on `5431`), not HAProxy on `5432`.

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
instance filename and `NODE_NAME` is correct on each machine.

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

## 4. Enable continuous WAL archival

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

Local peak usage is approximately one compressed base backup plus metadata and
temporary WAL compression. A failed export intentionally keeps the `.ready`
stage, so reserve capacity for that stage until publication can resume.

Network use includes the base backup upload and continuous WAL. CPU use depends
on `PG_COMPRESSION`; increase compression only after measuring backup duration,
source load, and restore speed.
