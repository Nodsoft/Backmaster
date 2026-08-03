# Configuration reference

This guide covers shared instance configuration. Component-specific behavior is
documented with the installed component: see the
[PostgreSQL driver](../drivers/postgresql.md) and
[rclone exporter](../exporters/rclone.md).

An instance joins one driver to one exporter. Its name is the filename below
`/etc/backmaster/instances.d` without `.env` and must contain lowercase letters,
digits, and hyphens.

Configuration files are sourced as shell environment files. Use simple
`KEY=value` assignments, quote values containing spaces, and do not place
untrusted content in them.

## Instance file

Example: `/etc/backmaster/instances.d/production-postgres.env`

```bash
INSTANCE_NAME=production-postgres
DRIVER=postgres
EXPORTER=rclone
NODE_NAME=axon

DRIVER_CONFIG=/etc/backmaster/drivers/postgres/production-postgres.env
EXPORTER_CONFIG=/etc/backmaster/exporters/rclone/production-postgres.env
EXPORTER_SECRET_FILE=/etc/backmaster/secrets/production-postgres-exporter.env

STAGING_ROOT=/var/lib/backmaster
MAX_AGE_SECONDS=82800
CONSUL_LOCK_KEY=service/backmaster/production-postgres
CONSUL_LOCK_TIMEOUT=30s

BACKUP_NAME_MODE=daily-time
BACKUP_NAME_SUFFIX_MODE=custom
BACKUP_NAME_SUFFIX_VALUE=axon
```

| Setting | Required | Meaning |
| --- | --- | --- |
| `INSTANCE_NAME` | yes | Must exactly match the requested instance filename |
| `DRIVER` | yes | Installed driver directory name |
| `EXPORTER` | yes | Installed exporter directory name |
| `NODE_NAME` | yes | Node identity used in logs and manifests |
| `DRIVER_CONFIG` | by driver | Driver policy file |
| `DRIVER_SECRET_FILE` | no | Optional driver credential file |
| `EXPORTER_CONFIG` | by exporter | Exporter policy file |
| `EXPORTER_SECRET_FILE` | no | Optional exporter credential file |
| `STAGING_ROOT` | no | Stage parent; default `/var/lib/backmaster` |
| `MAX_AGE_SECONDS` | no | Freshness gate for `run`; default `82800` (23 h) |
| `CONSUL_LOCK_KEY` | no | Shared lock; default `service/backmaster/INSTANCE` |
| `CONSUL_LOCK_TIMEOUT` | no | Lock wait; default `30s` |

Use the same `INSTANCE_NAME`, `CONSUL_LOCK_KEY`, exporter destination, and
`MAX_AGE_SECONDS` on all fallback-capable nodes. Give each node a distinct
`NODE_NAME`. `NODE_NAME` is metadata; it is independent from a name suffix.

## Naming

| Setting | Values | Default |
| --- | --- | --- |
| `BACKUP_NAME_MODE` | `daily`, `daily-serial`, `daily-time` | `daily-time` |
| `BACKUP_NAME_SUFFIX_MODE` | `none`, `hostname`, `custom` | `hostname` |
| `BACKUP_NAME_SUFFIX_VALUE` | Safe custom name | required for `custom` |

`daily` permits only one committed name per day and suffix. Use it when one
backup per node per day is guaranteed. `daily-serial` queries the shared remote
catalogue and chooses the next serial while the distributed lock is held.
`daily-time` is the safest general-purpose choice.

All dates and times are UTC. Hostname suffixes use `hostname --short`.

## PostgreSQL driver file

Example: `/etc/backmaster/drivers/postgres/production-postgres.env`

```bash
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=physical
PGDATABASE=postgres
PG_COMPRESSION=client-gzip:level=6
PG_CHECKPOINT=fast
PG_LOGICAL_COMPRESSION=6
PG_LOGICAL_GLOBALS_GZIP_LEVEL=6
# PG_DATABASE_INCLUDE=$'app\nmatrix'
# PG_DATABASE_EXCLUDE=$'scratch\ntest'
```

<!-- markdownlint-disable MD013 -->
| Setting | Mode | Default | Meaning |
| --- | --- | --- | --- |
| `PGHOST` | both | required | Unix socket directory or PostgreSQL host |
| `PGPORT` | both | required | PostgreSQL port |
| `PGUSER` | both | required | Backup role |
| `PG_BACKUP_MODE` | both | `physical` | `physical` or `logical` |
| `PGDATABASE` | both | `postgres` | Maintenance database used by readiness and logical discovery |
| `PG_COMPRESSION` | physical | `client-gzip:level=6` | `pg_basebackup --compress` value |
| `PG_CHECKPOINT` | physical | `fast` | `fast` or `spread` |
| `PG_LOGICAL_COMPRESSION` | logical | `6` | `pg_dump --compress` value |
| `PG_LOGICAL_GLOBALS_GZIP_LEVEL` | logical | `6` | Compression level for `globals.sql.gz` |
| `PG_DATABASE_INCLUDE` | logical | empty | Newline-delimited exact database names; empty means all |
| `PG_DATABASE_EXCLUDE` | logical | empty | Newline-delimited exact database names to omit |
<!-- markdownlint-enable MD013 -->

Logical mode discovers every connectable, non-template database. If an include
list is present, every named database must exist; a typo fails the backup rather
than silently creating an incomplete set. Exclusions are applied after includes
and therefore take precedence. If the filters select no databases, the backup
fails. Database names are passed directly to PostgreSQL tools, while dump
filenames are SHA-256-derived to prevent names from becoming filesystem paths.

Use ANSI-C quoting for multiple exact names in the shell environment file:

```bash
PG_DATABASE_INCLUDE=$'backmaster\nmatrix\nsynapse'
PG_DATABASE_EXCLUDE=$'scratch\ntest'
```

No storage credentials belong in the driver file. For more detail, see the
[PostgreSQL driver reference](../drivers/postgresql.md).

## Rclone exporter file

Example: `/etc/backmaster/exporters/rclone/production-postgres.env`

```bash
RCLONE_DESTINATION=azure:backups/production-postgresql
RETENTION_DAYS=14
MINIMUM_REDUNDANCY=2
HEALTHCHECK_MAX_AGE_SECONDS=129600
WAL_RETENTION_DAYS=15
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `RCLONE_DESTINATION` | required | `remote:path` root owned by this instance |
| `RETENTION_DAYS` | `14` | Age after which base backups may be removed |
| `MINIMUM_REDUNDANCY` | `2` | Newest completed base backups always preserved |
| `HEALTHCHECK_MAX_AGE_SECONDS` | `129600` | Critical remote age |
| `WAL_RETENTION_DAYS` | `15` | Archived WAL maximum age (physical only) |

Backup retention removes an item only when it is both older than
`RETENTION_DAYS` and outside the newest `MINIMUM_REDUNDANCY` items. Choose WAL
retention long enough to cover every retained physical backup you may restore.
Logical instances do not produce WAL objects.

Do not point unrelated instances at the same destination root. Backmaster owns
the `basebackups/` and `objects/` namespaces below it.

## Rclone secrets

For an environment-defined Azure remote named `azure`:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_ACCOUNT=REPLACE_ME
RCLONE_CONFIG_AZURE_KEY=REPLACE_ME
```

Where supported, prefer managed identity:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_ACCOUNT=REPLACE_ME
RCLONE_CONFIG_AZURE_USE_MSI=true
```

Protect the file for the service identity:

```bash
sudo chown root:postgres \
  /etc/backmaster/secrets/production-postgres-exporter.env
sudo chmod 0640 \
  /etc/backmaster/secrets/production-postgres-exporter.env
```

Never commit secret files. Verify that the chosen rclone authentication method
can list, read, write, and delete within only the intended destination. The
[rclone exporter reference](../exporters/rclone.md) documents other backends,
commands, remote layout, and retention behavior.

## Remote layout

```text
RCLONE_DESTINATION/
├── basebackups/
│   └── BACKUP_NAME/
│       ├── payload/
│       ├── checksums.sha256
│       └── manifest.json
└── objects/
    └── wal/
```

`manifest.json` is uploaded last. Its presence defines a completed backup;
payload left without a manifest is incomplete and ignored by the catalogue.
Physical payloads contain `pg_basebackup` tar archives. Logical payloads contain
`globals.sql.gz`, `databases.json`, and custom-format dumps under `databases/`.
