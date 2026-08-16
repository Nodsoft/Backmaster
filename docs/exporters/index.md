# Exporter development

Exporters publish sealed local stages to remote storage. They own destination
authentication, catalogue queries, publication commit semantics, generic
object transport, health checks, and remote retention. They do not know how a
driver produced the payload.

## Bundled exporters

- [rclone](rclone.md) supports Azure Blob Storage and other rclone backends.

## Contract

| Command | Contract |
| --- | --- |
| `latest-epoch` | Print newest committed manifest epoch, or exit 3 when empty |
| `next-serial DATE` | Print the next positive serial for a UTC day |
| `publish STAGE_DIR` | Durably publish payload, checksums, then manifest last |
| `retain` | Apply remote retention after a successful publish |
| `connectivitycheck` | Authenticate and verify the destination |
| `healthcheck` | Validate remote backup freshness |

The optional `put-file SOURCE KEY` and `get-file KEY DESTINATION` verbs provide
generic object transport for continuous recovery streams such as PostgreSQL
WAL. Keys are relative to an exporter-owned object namespace.

The manifest is the remote commit marker. `latest-epoch`, serial allocation,
health checks, and retention must ignore payloads without a committed manifest.
An exporter must return success from `publish` only after the manifest is
durable. The core removes a ready stage only after that success.

See the separate [driver contract](../drivers/index.md) for source-side
requirements.
