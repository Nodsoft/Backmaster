# AzCopy exporter

The AzCopy exporter publishes Backmaster stages directly to Azure Blob Storage
with Microsoft's `azcopy` command. Choose it when Backmaster only needs Azure
Storage and you want Azure-native authentication and transfer tooling. Choose
the [rclone exporter](rclone.md) when one configuration must remain portable to
non-Azure object stores.

Install it with:

```bash
sudo apt install backmaster-exporter-azcopy
```

The executable is installed at
`/usr/lib/backmaster/exporters/azcopy/exporter`. Invoke it through
`backmaster exporter INSTANCE ...`, not directly.

## Configuration

Select the exporter in the instance file:

```bash
EXPORTER=azcopy
EXPORTER_CONFIG=/etc/backmaster/exporters/azcopy/production-postgres.env
EXPORTER_SECRET_FILE=/etc/backmaster/secrets/production-postgres-azcopy.env
```

Create the exporter policy file:

```bash
AZCOPY_DESTINATION=https://example.blob.core.windows.net/backups/production-postgres
RETENTION_DAYS=14
MINIMUM_REDUNDANCY=2
HEALTHCHECK_MAX_AGE_SECONDS=129600
WAL_RETENTION_DAYS=15
```

<!-- markdownlint-disable MD013 -->
| Setting | Default | Meaning |
| --- | --- | --- |
| `AZCOPY_DESTINATION` | required | HTTPS Blob container URL plus an optional instance-specific prefix |
| `AZCOPY_SAS_TOKEN` | empty | Optional SAS query string; keep it in the secret file |
| `RETENTION_DAYS` | `14` | Days to retain committed backups; `unlimited` or `none` disables their cleanup |
| `MINIMUM_REDUNDANCY` | `2` | Minimum count of newest committed backups protected from age-based cleanup |
| `HEALTHCHECK_MAX_AGE_SECONDS` | `129600` | Maximum acceptable committed-backup age |
| `WAL_RETENTION_DAYS` | `15` | Days to retain WAL; `unlimited` or `none` disables WAL cleanup |
<!-- markdownlint-enable MD013 -->

Use a destination prefix dedicated to one Backmaster instance. The exporter
validates HTTPS URLs and URL-encodes every generated blob path. A SAS may be in
`AZCOPY_DESTINATION` or `AZCOPY_SAS_TOKEN`, but not both. Keeping it in the
secret file avoids mixing credentials into policy. See the
[secrets guide](../guides/secrets.md) for loading precedence, filesystem
permissions, validation, and rotation.

## Authentication

AzCopy supports Microsoft Entra identities and SAS authorization. The service
identity must be able to list, read, write, and delete blobs below the configured
prefix. `Storage Blob Data Contributor` provides the required data-plane access;
scope the assignment as narrowly as the deployment permits.

On an Azure resource, prefer a system-assigned managed identity:

```bash
AZCOPY_AUTO_LOGIN_TYPE=MSI
```

For a user-assigned identity, also set exactly one supported identity selector,
for example:

```bash
AZCOPY_AUTO_LOGIN_TYPE=MSI
AZCOPY_MSI_CLIENT_ID=REPLACE_ME
```

For an on-premises unattended service, a service principal secret file can use:

```bash
AZCOPY_AUTO_LOGIN_TYPE=SPN
AZCOPY_SPA_APPLICATION_ID=REPLACE_ME
AZCOPY_SPA_CLIENT_SECRET=REPLACE_ME
AZCOPY_TENANT_ID=REPLACE_ME
```

Alternatively, supply a narrowly scoped SAS:

```bash
AZCOPY_SAS_TOKEN='sv=REPLACE_ME&ss=b&...'
```

The leading `?` is optional. Quote SAS values because they contain shell
metacharacters. Do not place them on an interactive command line or commit them.
See Microsoft's guides for
[managed identity](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-authorize-managed-identity)
and
[service-principal](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-authorize-service-principal)
authorization.

## Publication and catalogue behavior

The remote layout matches the exporter contract:

```text
AZCOPY_DESTINATION/
├── basebackups/
│   └── BACKUP_NAME/
│       ├── payload/...
│       ├── checksums.sha256
│       └── manifest.json
└── objects/
    └── wal/...
```

`publish` uploads every regular stage file to its exact destination blob. It
skips `manifest.json` during that pass and uploads it separately, last. Only a
directory containing that manifest is a committed catalogue entry. A retry
overwrites an interrupted partial upload safely and recommits the manifest.

Catalogue operations use `azcopy list` to locate manifests, download only those
small files, and read their embedded creation epoch and backup name. This makes
freshness, daily serial allocation, and retention independent from blob listing
order and last-modified timestamps.

## Commands

<!-- markdownlint-disable MD013 -->
| Backmaster invocation | Behavior |
| --- | --- |
| `exporter INSTANCE connectivitycheck` | Authenticates and lists the destination |
| `exporter INSTANCE latest-epoch` | Prints the newest committed creation epoch; exits 3 if empty |
| `exporter INSTANCE next-serial DATE` | Returns the next committed serial for the UTC date |
| `exporter INSTANCE publish STAGE` | Uploads a sealed stage and commits its manifest last |
| `exporter INSTANCE retain` | Applies committed-backup and WAL retention |
| `exporter INSTANCE healthcheck` | Validates committed-backup freshness |
| `exporter INSTANCE put-file SOURCE KEY` | Uploads a recovery object below `objects/` |
| `exporter INSTANCE get-file KEY DESTINATION` | Downloads a recovery object from `objects/` |
<!-- markdownlint-enable MD013 -->

Recovery-object keys permit letters, digits, periods, underscores, slashes, and
hyphens. Absolute paths and keys containing `..` are rejected.

Normal operator checks use the higher-level interface:

```bash
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster run production-postgres --force
sudo -u postgres backmaster health production-postgres
```

## Retention

Base-backup retention sorts committed manifest data newest-first. It always
preserves the newest `MINIMUM_REDUNDANCY` entries, then recursively removes
additional entries older than `RETENTION_DAYS`.

Despite its name, `MINIMUM_REDUNDANCY` does not configure Azure replication.
It is the minimum number of committed Backmaster backups retained in this
instance's destination. With `RETENTION_DAYS=14` and `MINIMUM_REDUNDANCY=2`, the
two newest backups are protected at any age; every older backup remains until it
is older than 14 days. Use `0` only when no count-based safety floor is wanted.
The setting applies to physical and logical base backups, but not to WAL.

Set either cleanup clock independently to `unlimited` or its alias `none`:

```bash
RETENTION_DAYS=unlimited
WAL_RETENTION_DAYS=unlimited
```

When `RETENTION_DAYS` is unlimited, `MINIMUM_REDUNDANCY` is irrelevant. Numeric
`0` is a zero-day threshold, not an unlimited value. Uncommitted partial
directories are ignored and should be handled with a separate Azure lifecycle
rule or an operator cleanup after investigation.

WAL retention calls `azcopy remove` recursively with an ISO 8601
`--include-before` cutoff. Choose `WAL_RETENTION_DAYS` long enough to cover every
physical base backup that may be restored. Microsoft documents the command in
the [AzCopy remove reference](https://learn.microsoft.com/azure/storage/common/storage-ref-azcopy-remove).

## Validation and recovery

Before enabling a timer:

1. Run connectivity as the actual systemd service user.
2. Force one backup and confirm its `manifest.json` exists in Azure.
3. Run the health check and inspect the reported age.
4. Download and restore the backup, including checksum verification.
5. Exercise retention against a disposable prefix.

AzCopy writes job plans and logs to its configured locations. Use
`AZCOPY_JOB_PLAN_LOCATION` and `AZCOPY_LOG_LOCATION` in the exporter policy when
the service account's default locations are unsuitable. Do not put these below
the Backmaster stage that is being transferred.

If publication fails, Backmaster preserves the local `.ready` stage. Correct
authentication or destination access and run the instance again; publication
resumes before a new backup is created. See
[Troubleshooting](../guides/troubleshooting.md) for the shared recovery process.
