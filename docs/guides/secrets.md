# Secrets and credentials

Backmaster keeps credentials in separate environment files so policy can be
reviewed, packaged, and deployed without embedding authentication material.
This is a file-based secret mechanism, not an encrypted vault: the operating
system's ownership and permissions are the security boundary.

## File hierarchy

A typical instance uses four files:

```text
/etc/backmaster/
├── instances.d/production-postgres.env
├── drivers/postgres/production-postgres.env
├── exporters/azcopy/production-postgres.env
└── secrets/
    ├── production-postgres-driver.env
    └── production-postgres-exporter.env
```

The instance file selects the component files and optional secret files:

```bash
DRIVER_CONFIG=/etc/backmaster/drivers/postgres/production-postgres.env
DRIVER_SECRET_FILE=/etc/backmaster/secrets/production-postgres-driver.env
EXPORTER_CONFIG=/etc/backmaster/exporters/azcopy/production-postgres.env
EXPORTER_SECRET_FILE=/etc/backmaster/secrets/production-postgres-exporter.env
```

Driver and exporter secret files are independent. Omit either `*_SECRET_FILE`
setting when that component does not need credentials. PostgreSQL deployments
using peer authentication commonly need no driver secret file.

## Loading and precedence

For every command, Backmaster loads the instance file first. The selected
driver or exporter then loads its policy file followed by its secret file. A
value in a secret file therefore overrides the same value from the component
policy or inherited environment.

Files are sourced by Bash with automatic export enabled. Use only trusted,
root-managed files containing shell assignments:

```bash
KEY=value
QUOTED_VALUE='value containing spaces or shell metacharacters'
```

Do not use `export`, command substitutions, or executable shell logic. Quote
SAS tokens and other values containing `&`, `?`, spaces, or `$`. Backmaster
fails before contacting the source or destination when a configured file is
missing or unreadable.

Secret values are exported to the driver or exporter and any subprocess it
starts. They are not copied into manifests or staged payloads by Backmaster,
but root and processes running as the same Unix identity may be able to inspect
the process environment. Do not place secrets in command-line arguments, unit
files, logs, backup names, or destination paths.

## Ownership and permissions

Create a non-world-readable directory owned by root and the service group:

```bash
sudo install -d -m 0750 -o root -g postgres /etc/backmaster/secrets
sudo install -m 0640 -o root -g postgres source.env \
  /etc/backmaster/secrets/production-postgres-exporter.env
```

The group must match the `User=`/`Group=` that runs the instance. The bundled
PostgreSQL drop-in runs as `postgres`; a generic instance normally uses the
`backmaster` account. For a single dedicated service user, mode `0600` with
that user as owner is also appropriate. Never make a secret file world-readable.

Verify the complete path as the service identity:

```bash
sudo -u postgres test -r \
  /etc/backmaster/secrets/production-postgres-exporter.env
namei -l /etc/backmaster/secrets/production-postgres-exporter.env
```

Backmaster's systemd sandbox mounts `/etc/backmaster` read-only, which permits
reading credentials but prevents the service from modifying them. Keep secret
files outside package-managed example directories and exclude local deployment
trees from version control and configuration-management logs.

## PostgreSQL driver credentials

For password authentication, prefer a PostgreSQL passfile over an environment
password. Put only its protected path in the driver secret file:

```bash
PGPASSFILE=/etc/backmaster/secrets/production-postgres.pgpass
```

The passfile itself uses PostgreSQL's `host:port:database:user:password` format,
must be readable by the service identity, and must not grant group or world
access. For the packaged PostgreSQL service identity, install it separately
from the group-readable environment file:

```bash
sudo install -m 0600 -o postgres -g postgres source.pgpass \
  /etc/backmaster/secrets/production-postgres.pgpass
```

A TLS client configuration may instead or additionally reference
`PGSSLCERT`, `PGSSLKEY`, and `PGSSLROOTCERT` from the driver secret file. Avoid
`PGPASSWORD`: PostgreSQL discourages it because process environments may be
observable.

The [PostgreSQL driver reference](../drivers/postgresql.md#postgresql-client-environment)
lists every supported libpq pass-through variable and explains which connection
fields Backmaster sets explicitly.

## MongoDB driver credentials

Keep `MONGODB_URI` free of credentials and put authentication material in the
driver secret file:

```bash
MONGODB_USERNAME=backmaster
MONGODB_PASSWORD='REPLACE_ME'
# MONGODB_AUTH_MECHANISM=SCRAM-SHA-256
```

X.509 deployments may instead reference a protected client PEM with
`MONGODB_TLS_CERTIFICATE_KEY_FILE` and, when needed,
`MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD`. AWS IAM variables supported by the
MongoDB tools may also be supplied through the secret file. Prefer workload
identity and short-lived credentials over static passwords.

MongoDB's non-interactive command-line tools receive connection options as
arguments. On hosts where users can inspect one another's process arguments,
apply operating-system process isolation and use a dedicated service identity.
Never log an expanded command or enable shell tracing. See the
[MongoDB driver reference](../drivers/mongodb.md#configuration-reference) for
the complete authentication and TLS surface.

## Exporter examples

An rclone Azure account-key file may contain:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_ACCOUNT=REPLACE_ME
RCLONE_CONFIG_AZURE_KEY=REPLACE_ME
```

Prefer managed identity when available because it removes the long-lived key:

```bash
RCLONE_CONFIG_AZURE_TYPE=azureblob
RCLONE_CONFIG_AZURE_USE_MSI=true
```

AzCopy with an on-premises service principal uses:

```bash
AZCOPY_AUTO_LOGIN_TYPE=SPN
AZCOPY_SPA_APPLICATION_ID=REPLACE_ME
AZCOPY_SPA_CLIENT_SECRET=REPLACE_ME
AZCOPY_TENANT_ID=REPLACE_ME
```

On Azure, prefer `AZCOPY_AUTO_LOGIN_TYPE=MSI`. A SAS alternative must be quoted:

```bash
AZCOPY_SAS_TOKEN='sv=REPLACE_ME&ss=b&...'
```

See the [rclone](../exporters/rclone.md) and
[AzCopy](../exporters/azcopy.md) references for authentication-specific
settings and minimum destination permissions.

## Validation and rotation

Validate a new credential without creating a backup:

```bash
sudo -u postgres backmaster connectivity production-postgres
sudo -u postgres backmaster health production-postgres
```

For a default-user MongoDB instance, run the equivalent commands as
`backmaster`.

Each Backmaster invocation reads the files again, so a oneshot service does not
need a daemon restart after rotation. Replace a secret atomically, preserving
ownership and mode, then rerun `connectivity`. Keep the old credential valid
until the new check succeeds; revoke it immediately afterwards. If a scheduled
backup is already running, its process retains the old environment until that
run exits.

For an account-key or client-secret rotation:

1. Issue the replacement credential with the same least-privilege scope.
2. Install the updated secret file atomically.
3. Run `backmaster connectivity INSTANCE` as the service user.
4. Run `backmaster health INSTANCE` and inspect the journal.
5. Revoke the old credential and repeat the connectivity check.

Do not print the file or use `set -x` while troubleshooting. Report variable
names, file metadata, and command status only. If a secret is exposed in logs,
shell history, Git, or a support bundle, rotate it rather than only deleting the
visible copy.
