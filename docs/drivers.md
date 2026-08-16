# Driver and exporter development

Backmaster separates data consistency from storage transport with a durable
local staging boundary.

## Lifecycle

1. The core acquires the instance's Consul lock and asks the exporter for the
   latest committed backup.
2. The core resolves the backup name and creates a private partial stage under
   `STAGING_ROOT/INSTANCE`.
3. The driver runs `prepare PAYLOAD_DIR`. It may only produce local files.
4. The core adds `checksums.sha256` and `manifest.json`, then atomically renames
   the directory to `*.ready`.
5. The exporter publishes the ready stage. It uploads `manifest.json` last; the
   manifest is the remote commit marker.
6. Only after a successful publish does the core remove local staging and run
   exporter retention.

If export fails, the ready stage remains locally. The next locked run exports
it before considering a new backup. Partial remote objects are never visible
as completed backups because they have no committed manifest.

## Driver contract

Drivers own consistency and archive production, never credentials, remote
catalogues, upload, or retention.

| Command | Contract |
| --- | --- |
| `prepare PAYLOAD_DIR` | Produce a self-contained backup in the empty directory |
| `connectivitycheck` | Validate local source access and required tools |
| `healthcheck` | Validate source-specific backup readiness |

The core exports `BACKUP_NAME`. A driver must not write outside its supplied
payload directory except for explicitly documented transient operations.

## Exporter contract

Exporters own remote storage, credentials, catalogue queries, commit semantics,
and retention.

| Command | Contract |
| --- | --- |
| `latest-epoch` | Print newest committed manifest epoch, or exit 3 when empty |
| `next-serial DATE` | Print the next positive serial for a UTC day |
| `publish STAGE_DIR` | Durably publish payload, checksums, then manifest last |
| `retain` | Apply remote retention after a successful publish |
| `connectivitycheck` | Authenticate and verify the destination |
| `healthcheck` | Validate remote backup freshness |

The optional `put-file SOURCE KEY` and `get-file KEY DESTINATION` verbs support
continuous recovery streams such as PostgreSQL WAL without exposing a storage
provider to the data driver.

The bundled `rclone` exporter works with Azure Blob and other rclone backends.
Moving away from Azure normally requires only a new rclone remote and
`RCLONE_DESTINATION`; a purpose-built exporter can be added without changing a
driver.
