# Installation

Backmaster is distributed as modular Debian packages and can also be installed
from a source checkout. Debian packages are the recommended production path.

## Requirements

The core package installs its declared runtime dependencies, including Bash,
Consul, jq, systemd, coreutils, and findutils. A usable flow additionally needs:

- a healthy Consul agent reachable by the `consul` CLI;
- enough local staging space for one complete compressed backup;
- a driver package and its source-specific tools;
- an exporter package and access to its destination;
- synchronized system clocks on all participating nodes.

The PostgreSQL driver depends on `postgresql-client` and `gzip`. The rclone
exporter depends on `rclone`.

## Install Debian packages

After adding the Nodsoft package repository to APT, install the bundled flow:

```bash
sudo apt update
sudo apt install backmaster
```

For a custom combination, install components explicitly:

```bash
sudo apt install \
  backmaster-core \
  backmaster-driver-postgres \
  backmaster-exporter-rclone
```

All component packages require the exact same core version. Upgrade them from
the same repository transaction rather than mixing files from different builds.

To install downloaded workflow artifacts directly:

```bash
sudo apt install \
  ./backmaster-core_VERSION_all.deb \
  ./backmaster-driver-postgres_VERSION_all.deb \
  ./backmaster-exporter-rclone_VERSION_all.deb
```

Installing `./backmaster_VERSION_all.deb` as well is optional; it is only a
convenience metapackage.

## Installed layout

| Path | Contents |
| --- | --- |
| `/usr/bin/backmaster` | Core CLI |
| `/usr/lib/backmaster/drivers/` | Installed drivers |
| `/usr/lib/backmaster/exporters/` | Installed exporters |
| `/usr/lib/systemd/system/` | Reusable service and health units |
| `/etc/backmaster/` | Administrator-owned configuration |
| `/var/lib/backmaster/INSTANCE/` | Local staging state |
| `/usr/share/doc/backmaster-*/examples/` | Packaged examples |

The package creates a generic `backmaster` system user. A source-specific
systemd drop-in may replace it; the PostgreSQL example runs both backup and
health services as `postgres` so local peer authentication and data access work.

## Prepare configuration directories

```bash
sudo install -d -m 0755 \
  /etc/backmaster/instances.d \
  /etc/backmaster/drivers/postgres \
  /etc/backmaster/exporters/rclone
sudo install -d -m 0750 -o root -g postgres /etc/backmaster/secrets
```

Copy the examples from the package documentation or this repository, remove the
`.example` suffix, and edit every placeholder. The next guide explains every
setting: [Configuration reference](configuration.md).

## Build packages locally

On a Debian-compatible build host with `dpkg-deb`:

```bash
VERSION=0.1.0 ARCH=all ./packaging/build-deb.sh
```

The output directory defaults to `dist/` and contains the core, PostgreSQL
driver, rclone exporter, and metapackage. Override it with `OUT_DIR=/path`.

## Verify the install

```bash
backmaster --version
systemctl cat backmaster@.service
systemctl cat backmaster-health@.service
```

The services are templates and are not useful until an instance configuration
exists. Continue with [Configuration](configuration.md), then the guide for your
driver.
