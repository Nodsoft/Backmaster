# Driver development

Backmaster drivers isolate storage-engine knowledge from fleet orchestration.
A driver receives its instance environment from the core and may load one
non-secret configuration file plus one secrets file.

## Required commands

### `latest-epoch`

Print exactly one Unix epoch for the newest durable, completed backup. Exit 3
when the repository contains no completed backup. Any other non-zero status is
an operational failure and prevents a new backup from starting.

### `backup`

Create a consistent backup and return only after durable remote storage has
acknowledged it. A driver should stream or use bounded staging space. It must
not assume `/mnt/data` exists.

### `retain`

Apply the configured retention policy. It runs only after `backup` succeeds.
Retention should preserve a minimum redundancy and remove no recovery material
needed by the oldest retained backup.

### `healthcheck`

Check technology-specific recovery health. At minimum, validate base-backup
freshness. Drivers with continuous logs or journals should validate those too.

### `connectivitycheck`

Authenticate and verify repository access without writing backup data.

### `next-serial DATE`

Required when an instance uses `BACKUP_NAME_MODE=daily-serial`. Inspect the
durable shared catalogue and print the next positive integer for the supplied
UTC date. The core holds the distributed instance lock during this call, then
exports the complete `BACKUP_NAME` before invoking `backup`.

## Semantics owned by the core

The core owns:

- Consul mutual exclusion per instance;
- runner priority through staggered timers;
- shared-catalogue freshness and fallback;
- UTC naming shape, hostname/custom suffix resolution, and name validation;
- structured start/skip/complete logging;
- systemd lifecycle and resource priority.

Drivers own:

- consistency mechanism (`pg_basebackup`, `mongodump`, filesystem snapshot,
  mail-aware copy, and so on);
- archive format and cloud client;
- recovery-material retention;
- restore tooling and documentation.

The `backup` command must use the core-provided `BACKUP_NAME`. A driver owns
serial lookup because catalogue metadata and query tools are backend-specific.

Drivers that require a service-owned identity should ship instance-specific
systemd drop-ins. Do not bake a database or mail user into the shared unit:
PostgreSQL can run as `postgres`, MongoDB as a purpose-made backup identity,
and Maildir backup as an identity with narrowly scoped read access.

## Example future drivers

| Driver | Likely consistency mechanism | Notes |
| --- | --- | --- |
| `mongo` | `mongodump --archive --gzip` or filesystem snapshot | Replica-set oplog/PITR policy must be explicit |
| `mail` | Dovecot-aware snapshot or consistent Maildir archive | Preserve UID/GID, xattrs, ACLs, and symlinks |
| `filesystem` | snapshot plus streamed `tar`/restic | Do not silently cross mount points |

Do not force every driver into one archive implementation. The shared contract
is lifecycle and observability, not a universal file format.
