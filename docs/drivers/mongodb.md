# MongoDB driver

The MongoDB driver creates logical, database-granular backups with the official
MongoDB Database Tools. It discovers every database visible to the backup role,
applies exact include and exclude filters, and invokes `mongodump` once per
selected database.

Two payload layouts are available:

<!-- markdownlint-disable MD013 -->
| Format | Per-database output | Best for |
| --- | --- | --- |
| `archive` | One `.archive` or `.archive.gz` file | Selective downloads and simple restores |
| `directory` | A directory of BSON and metadata files | Collection-level inspection and selective restore |
<!-- markdownlint-enable MD013 -->

Archive with gzip and plain naming is the default. It produces one recognizable,
independently downloadable file per database. This driver does not create
storage-engine snapshots or continuous point-in-time recovery.

## Configuration reference

The instance selects the policy file with `DRIVER_CONFIG` and may load a
protected `DRIVER_SECRET_FILE`. The secret file is loaded second and wins when
both files set the same variable.

<!-- markdownlint-disable MD013 -->
| Setting | Required/default | Meaning |
| --- | --- | --- |
| `DRIVER_CONFIG` | required | Readable MongoDB driver policy file |
| `DRIVER_SECRET_FILE` | empty | Optional protected credentials file |
| `MONGODB_URI` | required | `mongodb://` or `mongodb+srv://` deployment URI; do not select a database |
| `MONGODB_USERNAME` | empty | Authentication username; keep in the secret file |
| `MONGODB_PASSWORD` | empty | Authentication password; keep in the secret file |
| `MONGODB_AUTH_DATABASE` | `admin` | Authentication source passed to both tools |
| `MONGODB_AUTH_MECHANISM` | tool default | Optional SCRAM, X.509, AWS, GSSAPI, or PLAIN mechanism supported by the installed tools |
| `MONGODB_DUMP_FORMAT` | `archive` | `archive` for one file per database or `directory` for BSON/metadata trees |
| `MONGODB_FILE_NAMING` | `plain` | `plain` database names or opaque `sha256` top-level names |
| `MONGODB_GZIP` | `true` | Enable `mongodump --gzip` |
| `MONGODB_NUM_PARALLEL_COLLECTIONS` | `4` | Positive `mongodump --numParallelCollections` value for each database |
| `MONGODB_DATABASE_INCLUDE` | empty | Exact newline-delimited database names; empty starts with every visible database |
| `MONGODB_DATABASE_EXCLUDE` | empty | Exact newline-delimited names removed after inclusion |
| `MONGODB_INCLUDE_SYSTEM_DATABASES` | `false` | Include `admin`, `config`, and `local` when selected |
| `MONGODB_DUMP_DB_USERS_AND_ROLES` | `false` | Add `--dumpDbUsersAndRoles` to each per-database dump |
| `MONGODB_READ_PREFERENCE` | tool default | Optional mode or JSON document passed to `mongodump --readPreference` |
| `MONGODB_TLS_CA_FILE` | empty | CA bundle; also enables TLS |
| `MONGODB_TLS_CERTIFICATE_KEY_FILE` | empty | Client certificate/private-key PEM; also enables TLS |
| `MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD` | empty | PEM password; keep in the secret file |
| `MONGODB_TLS_INSECURE` | `false` | Disable certificate and hostname verification; diagnostic use only |
<!-- markdownlint-enable MD013 -->

Assignments are exported, so AWS IAM credentials and proxy variables supported
by MongoDB tools may be placed in the protected secret file. Prefer workload
identity or short-lived credentials where possible. Do not embed credentials in
`MONGODB_URI`: command-line connection arguments may be visible to other local
processes on systems without process isolation.

`MONGODB_TLS_INSECURE=true` weakens both certificate-chain and hostname
verification. It should not be used for production backups. A `mongodb+srv://`
URI enables TLS by default according to MongoDB connection-string rules.

## Discovery and filtering

Discovery runs `listDatabases` with `authorizedDatabases: true`. The backup role
therefore sees only databases it is permitted to list. An explicitly included
name that is absent or unauthorized fails the backup; it is never silently
ignored. Exclusions win over includes. System databases are removed unless
`MONGODB_INCLUDE_SYSTEM_DATABASES=true`. A final empty selection also fails.

Use ANSI-C quoting for exact multiline lists:

```bash
MONGODB_DATABASE_INCLUDE=$'application\nanalytics\nsessions'
MONGODB_DATABASE_EXCLUDE=$'scratch\ntest'
```

Plain output names reject path separators, line breaks, `.` and `..`. SHA-256
naming keeps database names out of top-level archive object names; the index
always preserves the original name. Directory dumps necessarily retain the
MongoDB-created database subdirectory inside their opaque top-level directory.

## Payload contract

Default archive output:

```text
payload/
├── databases.json
└── databases/
    ├── analytics.archive.gz
    └── application.archive.gz
```

Directory output:

```text
payload/
├── databases.json
└── databases/
    └── application.dump/
        └── application/
            ├── events.bson.gz
            └── events.metadata.json.gz
```

`databases.json` records the source topology and replica-set name, dump format,
naming and compression policies, collection concurrency, original database
name, and relative path of every dump. The core then adds checksums and the
remote manifest, or wraps the complete payload in a configured whole-backup
archive.

Every `mongodump --db` invocation has its own read window. Each database dump
can be restored independently, but a backup spanning several databases is not
a single deployment-wide transaction or point-in-time snapshot. `--oplog`
cannot be combined with per-database `--db` dumps and is intentionally not
exposed. Use a MongoDB-supported deployment snapshot or dedicated backup system
when cross-database consistency or PITR is required.

## Commands

<!-- markdownlint-disable MD013 -->
| Backmaster command | Driver action |
| --- | --- |
| `backmaster connectivity INSTANCE` | Check tools, authenticate, and run discovery |
| `backmaster health INSTANCE` | Do the connectivity check and report topology plus visible database count |
| `backmaster run INSTANCE` | Discover, filter, dump, checksum, and publish through the configured exporter |
<!-- markdownlint-enable MD013 -->

The driver executable also implements the standard internal
`prepare PAYLOAD_DIR`, `connectivitycheck`, and `healthcheck` verbs.

## Dependencies and compatibility

Install matching, supported releases of `mongodb-mongosh` and
`mongodb-database-tools`. `mongodump` creates BSON data plus collection metadata
and indexes; `mongorestore` is the corresponding restore tool. MongoDB advises
restoring into a compatible MongoDB version or feature compatibility version.
Queryable Encryption collections are not supported by `mongodump`.

## Setup

Install the driver with the core and one exporter:

```bash
sudo apt install \
  backmaster-core \
  backmaster-driver-mongodb \
  backmaster-exporter-rclone
```

Copy the packaged examples:

```bash
docs=/usr/share/doc/backmaster-driver-mongodb/examples

sudo install -d -m 0755 /etc/backmaster/drivers/mongodb
sudo install -m 0644 \
  "$docs/config/instances/nsys-mongodb.env.example" \
  /etc/backmaster/instances.d/production-mongodb.env
sudo install -m 0644 \
  "$docs/config/drivers/mongodb.env.example" \
  /etc/backmaster/drivers/mongodb/production-mongodb.env
sudo install -m 0640 -o root -g backmaster \
  "$docs/config/drivers/mongodb.secrets.env.example" \
  /etc/backmaster/secrets/production-mongodb-driver.env
```

Configure the exporter under the same instance name and use a destination root
not shared with PostgreSQL or another MongoDB instance. Grant the backup role
`listDatabases` and read access to every selected database. Grant the additional
user/role privileges only when `MONGODB_DUMP_DB_USERS_AND_ROLES=true`.

The packaged services already run as `backmaster`, which is normally sufficient
for TCP or SRV connections. To order the backup after a local server without
changing its user, add matching service drop-ins:

```ini
[Unit]
After=mongod.service
```

Apply the ordering to backup and health services if both need it. `After=` does
not start MongoDB; add `Wants=` only if that coupling is intentional.

Commission before scheduling:

```bash
sudo -u backmaster backmaster connectivity production-mongodb
sudo systemctl start backmaster@production-mongodb.service
sudo -u backmaster backmaster health production-mongodb
journalctl -u backmaster@production-mongodb.service -n 200 --no-pager
```

Then inspect `databases.json`, download and restore at least one database on an
isolated deployment, and create the timer described in the
[systemd guide](../guides/systemd.md#create-a-backup-timer). See the
[MongoDB restore runbook](../guides/mongodb-restore.md) for exact commands.

## Sizing and load

The driver dumps databases sequentially. Within each database,
`MONGODB_NUM_PARALLEL_COLLECTIONS` controls concurrency. Increasing it can
reduce elapsed time but raises source I/O, CPU, memory, connection, and local
file-descriptor pressure. Measure restore speed as well as backup speed.

With `BACKUP_ARCHIVE_FORMAT=files`, peak staging is approximately the completed
payload plus metadata. Whole-backup archive modes temporarily require both the
payload and its final archive. A failed export intentionally retains the sealed
stage for retry.
