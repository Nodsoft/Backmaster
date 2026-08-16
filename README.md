# Backmaster

Backmaster is a small, fleet-oriented backup runner. Backup technologies live
in drivers; scheduling, priority/fallback, distributed locking, freshness, and
health reporting stay in the core.

PostgreSQL is the first driver. MongoDB, mail, filesystem trees, and other
services can be added without copying the orchestration logic.

## Model

| Concept | Example | Responsibility |
| --- | --- | --- |
| Instance | `nsys-postgres` | One protected dataset and its policy |
| Driver | `postgres` | Technology-specific backup/restore commands |
| Runner | `axon` | A fleet node capable of executing the instance |
| Repository | Azure Blob prefix | Durable off-node backup catalogue |

Every capable node receives the same instance name and driver configuration.
Its timer determines priority:

- Axon attempts `nsys-postgres` at 02:15 UTC.
- Myelin attempts it at 03:15 UTC.
- Myelin sees Axon's fresh backup and exits successfully, or runs when Axon's
  backup is missing.
- A Consul lock prevents overlapping runs.

There is no `/mnt/data` dependency. The PostgreSQL driver streams compressed
physical backups to Azure Blob Storage in bounded multipart chunks.

## Driver contract

A driver is an executable named `drivers/<name>/driver`. Backmaster invokes:

| Command | Output / behavior |
| --- | --- |
| `latest-epoch` | Print the latest completed backup's Unix epoch, or exit 3 if none exists |
| `backup` | Create and durably upload one backup |
| `retain` | Apply the instance's retention policy |
| `healthcheck` | Validate backup-specific health and exit non-zero when unhealthy |
| `connectivity` | Check repository access without creating data |

Drivers may expose extra verbs through `backmaster driver INSTANCE VERB ...`.
The PostgreSQL driver adds `wal-archive` and `wal-restore` for Patroni.

The core guarantees that `latest-epoch`, `backup`, and `retain` execute while
holding the instance's distributed lock. A driver must not implement its own
fleet priority rules.

## Layout

```text
bin/backmaster                 generic orchestrator
drivers/postgres/driver       first backup driver
config/instances/             instance examples
config/drivers/               driver examples and secrets templates
systemd/                      reusable service/health templates
deploy/{axon,myelin}/         per-node timer examples
docs/                         architecture and recovery decisions
```

## PostgreSQL flow

The first flow uses Barman Cloud:

- daily physical base backup through node-local PostgreSQL on port 5431;
- gzip compression and multipart streaming directly to Azure Blob Storage;
- continuous WAL archiving for point-in-time recovery;
- 14-day recovery window with at least two base backups;
- physical recovery of the entire PostgreSQL 18 cluster.

Azure Blob Storage serves the same architectural role as S3 but is not an
S3-compatible API. The driver uses Barman's native `azure-blob-storage`
provider.

## Installation sketch

Install the project under `/opt/backmaster`, link `bin/backmaster` into
`/usr/local/bin`, and install the systemd units. Create an unprivileged
`backmaster` service account for the generic default. Each driver can ship an
instance-specific systemd drop-in selecting a narrower service identity; the
PostgreSQL example runs as `postgres`. Copy the instance and driver
configuration into `/etc/backmaster`; PostgreSQL secrets must be
`0640 root:postgres`.

```bash
sudo -u postgres backmaster connectivity nsys-postgres
sudo -u postgres backmaster run nsys-postgres --force
sudo -u postgres backmaster health nsys-postgres
```

Enable Axon's timer on Axon and Myelin's timer on Myelin. Enable the generic
health timer on both:

```bash
systemctl enable --now backmaster@nsys-postgres.timer
systemctl enable --now backmaster-health@nsys-postgres.timer
```

Do not treat a flow as production-ready until its restore runbook has passed on
an isolated host.

## Adding another flow

For MongoDB, add `drivers/mongo/driver`, an instance such as
`config/instances/nsys-mongo.env.example`, and driver-specific configuration.
No changes to `bin/backmaster` or the systemd service templates should be
needed.

See [driver development](docs/drivers.md) for the exact lifecycle and failure
semantics.
