# Exporter development

Exporters publish sealed local stages to remote storage. They own destination
authentication, catalogue queries, publication commit semantics, generic
object transport, health checks, and remote retention. They do not know how a
driver produced the payload.

## Bundled exporters

- [rclone](rclone.md) supports Azure Blob Storage and other rclone backends.
- [AzCopy](azcopy.md) targets Azure Blob Storage with Microsoft's native
  transfer utility and identity integrations.

Each bundled exporter page is the canonical reference for that component's
settings, defaults, authentication, remote layout, commands, retention, and
operational constraints. Task-oriented guides link to those references rather
than duplicating their option tables.

## Contract

<!-- markdownlint-disable MD013 -->
| Command | Contract |
| --- | --- |
| `latest-epoch` | Print newest committed manifest epoch, or exit 3 when empty |
| `next-serial DATE` | Print the next positive serial for a UTC day |
| `publish STAGE_DIR` | Durably publish files or the configured archive, then manifest last |
| `retain` | Apply remote retention after a successful publish |
| `connectivitycheck` | Authenticate and verify the destination |
| `healthcheck` | Validate remote backup freshness |
<!-- markdownlint-enable MD013 -->

The optional `put-file SOURCE KEY` and `get-file KEY DESTINATION` verbs provide
generic object transport for continuous recovery streams such as PostgreSQL
WAL. Keys are relative to an exporter-owned object namespace.

The manifest is the remote commit marker. `latest-epoch`, serial allocation,
health checks, and retention must ignore payloads without a committed manifest.
An exporter must return success from `publish` only after the manifest is
durable. The core removes a ready stage only after that success.

`publish` must accept both core stage layouts. A files stage contains
`payload/`, `checksums.sha256`, and `manifest.json`. An archive stage contains
the archive named by `.artifact.file` and `manifest.json`; its payload and
checksums are inside the archive. Manifests without `.artifact` are legacy
files-layout stages.

See the separate [driver contract](../drivers/index.md) for source-side
requirements.
