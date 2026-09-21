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

These are all settings interpreted directly by the AzCopy exporter. AzCopy
authentication variables such as `AZCOPY_AUTO_LOGIN_TYPE` are passed through
to the command and are governed by the installed AzCopy version.

<!-- markdownlint-disable MD013 -->
| Setting | Default | Meaning |
| --- | --- | --- |
| `EXPORTER_CONFIG` | required | Readable exporter policy file selected by the instance |
| `EXPORTER_SECRET_FILE` | empty | Optional protected file sourced after the policy file |
| `AZCOPY_DESTINATION` | required | HTTPS Blob container URL plus an optional instance-specific prefix |
| `AZCOPY_SAS_TOKEN` | empty | Optional SAS query string; keep it in the secret file |
| `AZCOPY_LOG_LOCATION` | instance state | Absolute directory for AzCopy logs |
| `AZCOPY_JOB_PLAN_LOCATION` | instance state | Absolute directory for AzCopy job plans |
| `RETENTION_DAYS` | `14` | Days to retain committed backups; `unlimited` or `none` disables their cleanup |
| `MINIMUM_REDUNDANCY` | `2` | Minimum count of newest committed backups protected from age-based cleanup |
| `HEALTHCHECK_MAX_AGE_SECONDS` | `129600` | Maximum acceptable committed-backup age |
| `WAL_RETENTION_DAYS` | `15` | Days to retain WAL; `unlimited` or `none` disables WAL cleanup |
<!-- markdownlint-enable MD013 -->

Use a destination prefix dedicated to one Backmaster instance. The exporter
validates HTTPS URLs and URL-encodes every generated blob path. A SAS may be in
`AZCOPY_DESTINATION` or `AZCOPY_SAS_TOKEN`, but not both. Keeping it in the
secret file avoids mixing credentials into policy. The policy loads first and
the secret file second, so secret values override policy or inherited values.
See the
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
│       ├── payload/... + checksums.sha256, or backup.ARCHIVE
│       └── manifest.json
├── catalogue/
│   └── CREATED_EPOCH/
│       └── BACKUP_NAME.json
└── objects/
    └── wal/...
```

`publish` uploads every regular files-layout object or the configured archive
to its exact destination blob. It verifies an archive against the SHA-256 in
the manifest, skips `manifest.json` during the artifact pass, and uploads it
separately, after the payload. It then uploads an identical manifest to
`catalogue/CREATED_EPOCH/BACKUP_NAME.json` as the final publication step.
`publish` succeeds only when both manifests are durable. If catalogue publication
fails, the core keeps the `.ready` stage; the next run retries that same stage.

Catalogue records are uploaded with `--block-blob-tier=Hot`. Keep `catalogue/`
outside every Azure lifecycle archival and deletion rule: only backup data under
`basebackups/` and recovery data under `objects/` should follow those rules.
Uploading as Hot does not override a lifecycle rule that archives the blob later.

Freshness and health checks list catalogue keys, select the largest numeric
creation epoch, and download **only that record**. They also check that its
per-backup manifest still exists by listing names, without downloading it.
Directory-name order, host suffixes, blob last-modified times, and the storage
tiers of older backups do not affect selection. If the newest record cannot be
read or validated, the check fails; it does not silently fall back to an older one.

Daily serial allocation lists per-backup manifest names for the requested date.
It includes legacy backups and never downloads their manifests. Retention uses
catalogue keys without downloading historical records or archived manifests.
All listing failures propagate as errors, rather than an empty backup store.

Backup names identify one generation. A retry with the same sealed manifest is
allowed, but publishing a different manifest under an already committed name is
rejected. Use `daily-time` or `daily-serial` for multiple backups per day. With
`daily`, a forced second backup using the same name must use a different naming
mode or wait until the next day.

## Migrating existing backups

Upgrade the AzCopy exporter on **all nodes sharing the destination** before
resuming timers. Older exporters do not publish catalogue records; mixing old
and new writers can make freshness checks miss newly written backups.
Pause backup and health timers, wait for active runs to finish, and perform the
migration with one operator. Direct exporter commands, including import and
retention, do not acquire the core's Consul lock.

An empty catalogue with existing per-backup manifests produces an explicit
migration error. It is not treated as an empty store and never triggers a scan
of historical manifest contents. Choose one of these bootstrap methods:

1. Import the **newest verified completed backup** while its manifest is readable:

   ```bash
   sudo -u postgres backmaster exporter production-postgres catalogue-import BACKUP_NAME
   ```

   Replace `BACKUP_NAME` with the exact remote directory name. Only that manifest
   is downloaded. Import validates its name and integer creation epoch, then
   publishes the Hot catalogue record. Importing the same generation is
   idempotent. An archived manifest must be rehydrated before it can be imported;
   other archived backups do not need rehydration.

2. Create one fresh backup with a unique name:

   ```bash
   sudo -u postgres backmaster run production-postgres --force
   ```

   Use `daily-time` or `daily-serial` in the instance configuration to avoid a
   collision with an existing daily backup. Prepare the state directory and use
   the actual service user as described in [Operations](../guides/operations.md#direct-cli-runs).
   The command still takes the Consul lock. If a `.ready` stage exists, it resumes
   that stage first; check its age and run again if a fresh backup is needed.

After bootstrap, run `backmaster health production-postgres`, confirm the new
record is online, and resume the timers. Existing backups without catalogue
records remain untouched. Numeric retention reports their count and does not
count them toward `MINIMUM_REDUNDANCY`. Import older backups individually to
enroll them in retention, or manage them separately with Azure lifecycle rules.
Importing an old backup makes it eligible for deletion on the next retention run.

Never seed the catalogue from an arbitrary older backup and assume it represents
the newest backup. Import all recent candidates if their order is uncertain, or
use the forced-backup method. A successfully indexed backup makes the catalogue
authoritative for freshness; legacy unindexed entries are not read automatically.

## Commands

<!-- markdownlint-disable MD013 -->
| Backmaster invocation | Behavior |
| --- | --- |
| `exporter INSTANCE connectivitycheck` | Authenticates and lists the destination |
| `exporter INSTANCE latest-epoch` | Prints the newest committed creation epoch; exits 3 if empty |
| `exporter INSTANCE next-serial DATE` | Returns the next committed serial for the UTC date |
| `exporter INSTANCE publish STAGE` | Uploads a sealed stage, its manifest, and finally its catalogue record |
| `exporter INSTANCE catalogue-import NAME` | Imports one existing readable manifest into the online catalogue |
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
sudo systemctl start backmaster@production-postgres.service
sudo -u postgres backmaster health production-postgres
```

The service creates the instance staging directory for its effective user. If
you need a direct CLI backup, prepare that directory as described in
[Operations](../guides/operations.md#direct-cli-runs).

## Retention

Base-backup retention sorts indexed creation epochs newest-first. It always
preserves the newest `MINIMUM_REDUNDANCY` entries, then recursively removes
additional entries older than `RETENTION_DAYS`.

It removes the catalogue record before deleting the backup directory. If the
record cannot be removed, it leaves the backup intact. If the directory removal
fails afterward, the run reports failure and the remaining data is unindexed;
inspect it before explicitly importing it again or completing its removal.
Manual deletion or external lifecycle deletion must also remove corresponding
catalogue records. Archival alone does not require any catalogue changes.

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

Backmaster sets AzCopy's job-plan and log locations to
`/var/lib/backmaster/INSTANCE/azcopy/plans` and
`/var/lib/backmaster/INSTANCE/azcopy/logs`. It creates both directories before
the first AzCopy command, including catalogue and health checks. This prevents
AzCopy from falling back to the service user's home, which is read-only under
the packaged systemd sandbox.

Override `AZCOPY_JOB_PLAN_LOCATION` or `AZCOPY_LOG_LOCATION` in the exporter
policy only when necessary. Overrides must be absolute, writable by the unit's
effective user, permitted by the systemd sandbox, and outside the staged backup
payload.

If publication fails, Backmaster preserves the local `.ready` stage. Correct
authentication or destination access and run the instance again; publication
resumes before a new backup is created. See
[Troubleshooting](../guides/troubleshooting.md) for the shared recovery process.
