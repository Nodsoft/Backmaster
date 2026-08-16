# rclone exporter

The bundled rclone exporter publishes Backmaster stages to any backend supported
by rclone. Azure Blob Storage is the initial deployment target, but the exporter
contains no Azure-specific upload logic: changing the remote and credentials is
normally sufficient to use another backend.

Install it with:

```bash
sudo apt install backmaster-exporter-rclone
```

The executable is installed at
`/usr/lib/backmaster/exporters/rclone/exporter`. Invoke it through the
`backmaster exporter INSTANCE ...` command so the instance and exporter
configuration are loaded consistently.

## Configuration

An instance selects the exporter with `EXPORTER=rclone` and points
`EXPORTER_CONFIG` at its policy file. A typical Azure policy file is:

```bash
RCLONE_DESTINATION=azure:backups/nsys-postgresql
RETENTION_DAYS=14
MINIMUM_REDUNDANCY=2
HEALTHCHECK_MAX_AGE_SECONDS=129600
WAL_RETENTION_DAYS=15
EXPORTER_SECRET_FILE=/etc/backmaster/secrets/production-postgres-exporter.env
```

<!-- markdownlint-disable MD013 -->
| Setting | Default | Meaning |
| --- | --- | --- |
| `RCLONE_DESTINATION` | required | Remote, container/bucket, and root path |
| `RETENTION_DAYS` | `14` | Days to retain completed backups; `unlimited` or `none` disables their cleanup |
| `MINIMUM_REDUNDANCY` | `2` | Minimum count of newest committed backups protected from age-based cleanup |
| `HEALTHCHECK_MAX_AGE_SECONDS` | `129600` | Maximum acceptable committed-backup age |
| `WAL_RETENTION_DAYS` | `15` | Days to retain WAL; `unlimited` or `none` disables WAL cleanup |
| `EXPORTER_SECRET_FILE` | empty | Optional protected file sourced after the policy file |
<!-- markdownlint-enable MD013 -->

Keep credentials in `EXPORTER_SECRET_FILE`, not in the instance or policy file.
The [secrets guide](../guides/secrets.md) documents loading precedence,
filesystem permissions, validation, and rotation.
For an rclone remote named `azure`, an account-key secret file can contain:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_ACCOUNT=REPLACE_ME
RCLONE_CONFIG_AZURE_KEY=REPLACE_ME
```

On an Azure host with an appropriate managed identity, prefer:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_USE_MSI=true
```

The uppercase portion of each `RCLONE_CONFIG_<REMOTE>_*` variable must match the
remote name in `RCLONE_DESTINATION`. Use permissions limited to listing,
reading, writing, and deleting objects under the dedicated Backmaster path.

To move to another backend, configure another rclone remote and change
`RCLONE_DESTINATION`, for example `s3remote:bucket/backmaster`. Verify the new
backend's consistency, authentication, encryption, immutability, and lifecycle
behavior during a restore drill before production cutover.

## Remote layout

The exporter owns two namespaces below `RCLONE_DESTINATION`:

```text
basebackups/BACKUP_NAME/
  payload/...
  checksums.sha256
  manifest.json
objects/
  wal/...
```

`publish` copies the payload and checksums first, then uploads `manifest.json`
last. Only a directory containing a valid manifest is a completed catalogue
entry. An interrupted upload may leave remote payload files, but freshness,
serial allocation, and retention ignore them until publication commits.

Use a destination root dedicated to one Backmaster instance. Sharing a root
between unrelated instances mixes their catalogue, naming, health, and retention
domains.

## Commands

<!-- markdownlint-disable MD013 -->
| Backmaster invocation | Behavior |
| --- | --- |
| `exporter INSTANCE connectivitycheck` | Verifies that rclone can list the destination |
| `exporter INSTANCE latest-epoch` | Prints the newest committed creation epoch; exits 3 if empty |
| `exporter INSTANCE next-serial DATE` | Allocates the next serial seen for the UTC date |
| `exporter INSTANCE publish STAGE` | Publishes a sealed stage and commits its manifest last |
| `exporter INSTANCE retain` | Applies backup and WAL retention |
| `exporter INSTANCE healthcheck` | Validates that a committed backup is recent enough |
| `exporter INSTANCE put-file SOURCE KEY` | Uploads a recovery object below `objects/` |
| `exporter INSTANCE get-file KEY DESTINATION` | Downloads a recovery object from `objects/` |
<!-- markdownlint-enable MD013 -->

`put-file` and `get-file` accept relative keys containing letters, digits,
periods, underscores, slashes, and hyphens. Absolute paths and any key containing
`..` are rejected.

Normal operator checks use the higher-level commands:

```bash
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster health production-postgres
sudo -u postgres backmaster exporter production-postgres latest-epoch
```

## Retention

After a successful publication, `retain` orders committed manifests from newest
to oldest. A backup is removed only if it is both older than `RETENTION_DAYS`
and outside the newest `MINIMUM_REDUNDANCY` committed backups.

`MINIMUM_REDUNDANCY` is a protected backup count, not a replica count or a
storage-redundancy setting. It counts committed manifests in this instance's
destination, regardless of whether the driver produced physical or logical
backups. For example, with `RETENTION_DAYS=14` and `MINIMUM_REDUNDANCY=2`, the
newest two committed backups survive even when both are older than 14 days;
older backups survive until they cross 14 days. Setting it to `0` disables this
count guard and allows every age-expired base backup to be removed. It does not
protect WAL objects.

Set either retention clock independently to `unlimited` (or the alias `none`)
to disable its cleanup:

```bash
RETENTION_DAYS=unlimited
WAL_RETENTION_DAYS=unlimited
```

When base-backup retention is unlimited, `MINIMUM_REDUNDANCY` has no effect.
Numeric `0` means a zero-day age threshold; it does not mean unlimited.

Choose WAL retention long enough to cover every retained physical base backup
that may be used for point-in-time recovery. Logical-only flows do not create
WAL objects, though the retention pass remains harmless.

Object-store lifecycle policies, versioning, and immutability are complementary
controls. Ensure provider-side deletion rules do not remove payloads, manifests,
or WAL earlier than Backmaster expects.

## Validation and recovery

Before enabling a timer:

1. Run connectivity as the service identity.
2. Force one backup and confirm `manifest.json` exists remotely.
3. Run health and verify the reported age.
4. Download the backup, verify `checksums.sha256`, and complete the relevant
   restore guide.
5. Test retention against a disposable destination before shortening it in
   production.

If export fails, keep the local `.ready` stage. Correct destination access and
run the instance again; the core resumes that stage before creating a new
backup. See [Troubleshooting](../guides/troubleshooting.md) for failure-specific
checks.
