# PostgreSQL driver

The PostgreSQL driver has two selectable modes:

<!-- markdownlint-disable MD013 -->
| Mode | Produces | Best for | Does not provide |
| --- | --- | --- | --- |
| `physical` | Compressed `pg_basebackup` plus optional continuous WAL | Cluster/member rebuild and PITR | Per-database selection |
| `logical` | Globals plus one configurable `pg_dump` per database | Selective backup, migration, object/database restore | PITR or a Patroni member image |
<!-- markdownlint-enable MD013 -->

`physical` remains the default. Use separate Backmaster instances and remote
destination roots if you want both modes: for example `postgres-physical` and
`postgres-logical`. This gives each flow independent freshness, naming,
retention, monitoring, and restore history.

## Configuration reference

The instance file selects the driver policy with `DRIVER_CONFIG` and may select
a protected credential file with `DRIVER_SECRET_FILE`. The driver loads the
policy first and the secret file second, so the secret file wins when both set
the same variable. Both files are sourced as Bash environment files; see
[Secrets and credentials](../guides/secrets.md) for syntax and permissions.

These are all settings interpreted directly by the PostgreSQL driver:

<!-- markdownlint-disable MD013 -->
| Setting | Mode | Required/default | Passed to or used for |
| --- | --- | --- | --- |
| `DRIVER_CONFIG` | both | required | Readable driver policy file selected by the instance |
| `DRIVER_SECRET_FILE` | both | empty | Optional protected file loaded after the policy file |
| `PGHOST` | both | required | `--host` for every PostgreSQL client; use a socket directory or host name |
| `PGPORT` | both | required | `--port` for every PostgreSQL client |
| `PGUSER` | both | required | `--username` for every PostgreSQL client |
| `PGDATABASE` | both | `postgres` | Readiness database; also logical discovery and `pg_dumpall --globals-only` connection database |
| `PG_BACKUP_MODE` | both | `physical` | Exactly `physical` or `logical` |
| `PG_COMPRESSION` | physical | `client-gzip:level=6` | `pg_basebackup --compress`; accepted syntax depends on the installed client version |
| `PG_CHECKPOINT` | physical | `fast` | `pg_basebackup --checkpoint`; PostgreSQL accepts `fast` or `spread` |
| `PG_LOGICAL_FORMAT` | logical | `custom` | `custom` writes restorable `.dump` archives; `plain` writes directly readable `.sql` scripts |
| `PG_LOGICAL_FILE_NAMING` | logical | `sha256` | `sha256` hides database names in filenames; `plain` writes the exact database name before the extension |
| `PG_LOGICAL_COMPRESSION` | logical | `6` | `pg_dump --compress` for every custom-format database archive; accepted syntax depends on the installed client version |
| `PG_LOGICAL_GLOBALS_GZIP_LEVEL` | logical | `6` | `gzip` level for `globals.sql.gz`; use `1` through `9` |
| `PG_DATABASE_INCLUDE` | logical | empty | Exact, newline-delimited database names; empty selects every discovered database |
| `PG_DATABASE_EXCLUDE` | logical | empty | Exact, newline-delimited database names removed after inclusion |
<!-- markdownlint-enable MD013 -->

Backmaster deliberately passes compression values to the installed PostgreSQL
tools instead of maintaining a second version-specific parser. An invalid or
unsupported value therefore fails in `pg_basebackup` or `pg_dump`. The package
uses tar format, streamed WAL, SHA-256 manifests, and a backup label in physical
mode; those choices are fixed and have no Backmaster setting. Logical dumps
are produced sequentially. `PG_LOGICAL_COMPRESSION` applies only to `custom`;
plain SQL output is intentionally uncompressed so a downloaded `.sql` file can
be inspected and passed directly to `psql`.

The core also supplies internal lifecycle context: `BACKUP_NAME` becomes the
physical backup label, while `INSTANCE_NAME`, `STAGING_ROOT`, and
`EXPORTER_EXEC` support WAL temporary files and exporter object transport.
Administrators configure their source values in the instance file; they should
not override the resolved runtime values in a driver policy or secret file.

### PostgreSQL client environment

All assignments in the driver policy and secret files are exported. The
PostgreSQL clients therefore also honor their supported libpq environment
variables. `PGHOST`, `PGPORT`, `PGUSER`, and the relevant database name are
always passed explicitly by the driver; a service definition cannot replace
those required settings. Service definitions and environment variables may
supply connection parameters the driver does not set explicitly.

<!-- markdownlint-disable MD013 -->
| Purpose | Pass-through variables |
| --- | --- |
| Password and service files | `PGPASSFILE`, `PGPASSWORD`, `PGSERVICE`, `PGSERVICEFILE`, `PGSYSCONFDIR` |
| Routing and connection policy | `PGHOSTADDR`, `PGCONNECT_TIMEOUT`, `PGTARGETSESSIONATTRS`, `PGLOADBALANCEHOSTS`, `PGOPTIONS`, `PGAPPNAME` |
| Authentication policy | `PGREQUIREAUTH`, `PGREQUIREPEER`, `PGCHANNELBINDING` |
| TLS | `PGSSLMODE`, `PGSSLNEGOTIATION`, `PGSSLCERT`, `PGSSLKEY`, `PGSSLCERTMODE`, `PGSSLROOTCERT`, `PGSSLCRL`, `PGSSLCRLDIR`, `PGSSLSNI`, `PGSSLMINPROTOCOLVERSION`, `PGSSLMAXPROTOCOLVERSION` |
| GSSAPI | `PGGSSENCMODE`, `PGKRBSRVNAME`, `PGGSSLIB`, `PGGSSDELEGATION` |
| Protocol and encoding | `PGMINPROTOCOLVERSION`, `PGMAXPROTOCOLVERSION`, `PGCLIENTENCODING` |
| Session defaults | `PGDATESTYLE`, `PGTZ`, `PGGEQO` |
<!-- markdownlint-enable MD013 -->

The deprecated `PGREQUIRESSL` and `PGSSLCOMPRESSION` variables are also passed
through, but new configurations should use `PGSSLMODE` and current TLS
settings. PostgreSQL may add variables over time; the installed client's
[libpq environment-variable reference](https://www.postgresql.org/docs/current/libpq-envars.html)
is authoritative for values and version availability.

Prefer peer authentication for a local socket or `PGPASSFILE` for password
authentication. PostgreSQL discourages `PGPASSWORD` because process
environments can be observable. Certificate/key/passfile paths must be
readable by the systemd service identity, and PostgreSQL enforces restrictive
permissions on password and private-key files.

### Database selection

Logical discovery runs this equivalent query through `psql`, ordered by name:

```sql
SELECT datname
FROM pg_database
WHERE datallowconn AND NOT datistemplate
ORDER BY datname;
```

Each non-empty include entry must occur in that result or the run fails. The
driver then applies the include list, followed by the exclude list; exclusions
win. Blank lines are ignored, but all other characters—including leading or
trailing spaces—are significant. If no database remains, the run fails before
publishing a globals-only backup.

Use Bash ANSI-C quoting for multiple names:

```bash
PG_DATABASE_INCLUDE=$'backmaster\nmatrix\nsynapse'
PG_DATABASE_EXCLUDE=$'scratch\ntest'
```

Leave both values empty to dump every connectable, non-template database.

### Logical output names and formats

Naming and dump format are independent. The defaults retain Backmaster's
original behavior:

```bash
PG_LOGICAL_FILE_NAMING=sha256
PG_LOGICAL_FORMAT=custom
```

For human-readable, directly downloadable SQL files, use:

```bash
PG_LOGICAL_FILE_NAMING=plain
PG_LOGICAL_FORMAT=plain
```

That produces paths such as `databases/backmaster.sql`. Plain naming preserves
the PostgreSQL database name exactly, including spaces and Unicode. For path
safety, the driver rejects a selected name containing `/`, carriage return, or
newline instead of modifying it or creating nested paths. Use `sha256` naming
if such a name must be backed up. In all modes, `databases.json` is the
authoritative database-to-file mapping and records both selected policies.

### Commands and dependencies

Invoke driver verbs through `backmaster driver INSTANCE ...`; direct execution
does not load the instance environment. `prepare` is an internal lifecycle verb
and expects an existing, empty payload directory created by the core.

<!-- markdownlint-disable MD013 -->
| Invocation | Arguments and behavior | External commands |
| --- | --- | --- |
| `driver INSTANCE connectivitycheck` | Checks required tools and local source readiness | `pg_isready`, plus mode-specific tools below |
| `driver INSTANCE healthcheck` | Runs connectivity and prints the selected backup mode | same as connectivity |
| `driver INSTANCE prepare PAYLOAD_DIR` | Creates the selected payload; normally called only by `backmaster run` | physical: `pg_basebackup`; logical: `psql`, `pg_dump`, `pg_dumpall`, `jq`, `gzip`, `sha256sum` |
| `driver INSTANCE wal-archive WAL_PATH` | Gzip-compresses and exports one WAL segment; physical mode only | `gzip`, exporter `put-file` |
| `driver INSTANCE wal-restore WAL_NAME DESTINATION` | Downloads and decompresses one WAL segment; physical mode only | `gzip`, exporter `get-file` |
<!-- markdownlint-enable MD013 -->

`connectivitycheck` verifies mode-specific PostgreSQL commands and source
readiness without producing a backup. `healthcheck` performs that same local
check and reports the selected mode. It does not prove that a dump can read
every object; the first intentional backup and a restore drill remain required.

### Payload format

Physical mode writes PostgreSQL's tar-format base-backup files directly below
`payload/`; names and extensions depend on server tablespaces and
`PG_COMPRESSION`. The streamed WAL needed to make that base backup internally
consistent is included by `pg_basebackup`. Continuous WAL exported separately
under `objects/wal/` is what extends recovery beyond the base backup.

Logical mode produces:

```text
payload/
├── globals.sql.gz
├── databases.json
└── databases/
    └── SHA256.dump | DATABASE_NAME.dump | SHA256.sql | DATABASE_NAME.sql
```

`globals.sql.gz` is the plain SQL output of `pg_dumpall --globals-only`.
`databases.json` records the logical dump format, naming policy, original
database name, and relative path for every selected database. Custom archives
use `.dump` and restore through `pg_restore`; plain dumps use `.sql` and restore
through `psql`. SHA-256 naming prevents database names from appearing in object
paths. The core adds `checksums.sha256` and `manifest.json` outside `payload/`
after the driver succeeds.

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
described in the [configuration guide](../guides/configuration.md). Start from
the packaged examples:

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
file, select `PG_BACKUP_MODE=physical` or `PG_BACKUP_MODE=logical`. The complete
option reference is above; a logical configuration might use:

```bash
PG_BACKUP_MODE=logical
PG_LOGICAL_FORMAT=plain
PG_LOGICAL_FILE_NAMING=plain
PGDATABASE=postgres
PG_DATABASE_INCLUDE=$'backmaster\nmatrix\nsynapse'
PG_DATABASE_EXCLUDE=$'scratch\ntest'
```

Backmaster always includes `globals.sql.gz` for roles and tablespaces, even when
database filtering is used.

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
sudo systemctl start backmaster@production-postgres.service
```

Starting the service is important: systemd creates the configured instance
state directory with the ownership of the effective `User=postgres` drop-in.
For a direct CLI run, first follow the
[manual state-directory procedure](../guides/operations.md#direct-cli-runs).

The first `health` may report no completed export; that is expected before the
first successful backup. After `run`, inspect the journal and remote manifest:

```bash
journalctl -u backmaster@production-postgres.service -n 100 --no-pager
sudo -u postgres backmaster exporter production-postgres latest-epoch
```

Run `backmaster health production-postgres` again. Then complete the
[restore runbook](../guides/postgres-restore.md) on an isolated host.

For logical mode, inspect `payload/databases.json` in the exported backup. It is
the authoritative map from original database names to safe dump filenames.

## 6. Schedule one node

Backmaster does not package a universal backup timer. Follow the
[systemd units and timers guide](../guides/systemd.md#create-a-backup-timer) to
create an instance-specific timer with the desired schedule, validate its
calendar, and enable both backup and health timers. Do this only after the
commissioning backup and restore test above succeed.

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
