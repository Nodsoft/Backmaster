# Driver development

Drivers turn a source system into a self-contained local backup payload. They
own source consistency and archive production, but have no knowledge of remote
storage or credentials.

## Bundled drivers

- [PostgreSQL](postgresql.md) supports physical base backups with WAL and
  filtered logical dumps.

Each bundled driver page is the canonical reference for that component's
settings, defaults, accepted values, credentials, output, dependencies, and
operational constraints. Task-oriented examples may appear in the guides, but
must link back to the component reference instead of maintaining a second
option table.

## Lifecycle

1. The core acquires the instance's Consul lock and asks the exporter for the
   latest committed backup.
2. The core resolves the backup name and creates a private partial stage under
   `STAGING_ROOT/INSTANCE`.
3. The driver runs `prepare PAYLOAD_DIR`. It may only produce local files.
4. The core adds `checksums.sha256` and `manifest.json`, then atomically renames
   the directory to `*.ready`.
5. The configured exporter publishes the ready stage and commits it remotely.
6. Only after a successful publish does the core remove local staging and run
   exporter retention.

If export fails, the ready stage remains locally. The next locked run exports
it before considering a new backup. Partial remote objects are never visible
as completed backups because they have no committed manifest.

## Contract

| Command | Contract |
| --- | --- |
| `prepare PAYLOAD_DIR` | Produce a self-contained backup in the empty path |
| `connectivitycheck` | Validate local source access and required tools |
| `healthcheck` | Validate source-specific backup readiness |

The core exports `BACKUP_NAME`. A driver must not write outside its supplied
payload directory except for explicitly documented transient operations. It
must never query a remote catalogue, apply remote retention, or contain
destination credentials.

Drivers may call optional exporter object verbs through the core for continuous
recovery streams. For example, PostgreSQL WAL archival uses `put-file` and
`get-file`; the driver still never sees which storage provider implements them.

See the separate [exporter contract](../exporters/index.md) for transport-side
requirements.
