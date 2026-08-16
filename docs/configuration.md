# Configuration reference

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
PG_COMPRESSION=client-gzip:level=6
PG_CHECKPOINT=fast
```

| Setting | Meaning |
| --- | --- |
| `PGHOST` | Unix socket directory or host accepted by PostgreSQL clients |
| `PGPORT` | Direct PostgreSQL member port, not a load-balanced write endpoint |
| `PGUSER` | Role used by `pg_basebackup` |
| `PG_COMPRESSION` | Value passed to `pg_basebackup --compress` |
| `PG_CHECKPOINT` | `fast` or `spread`, passed to `pg_basebackup` |

No storage credentials belong in the driver file.

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
| `WAL_RETENTION_DAYS` | `15` | Age after which archived WAL may be removed |

Base-backup retention removes an item only when it is both older than
`RETENTION_DAYS` and outside the newest `MINIMUM_REDUNDANCY` items. Choose WAL
retention long enough to cover every retained base backup you may restore.

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
can list, read, write, and delete within only the intended destination.

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
