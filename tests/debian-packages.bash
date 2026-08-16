#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT

readonly version="0.1.0-package-test"
VERSION="$version" ARCH=all OUT_DIR="$temporary/dist" PKGROOT="$temporary/pkgroot" \
    "$ROOT/packaging/build-deb.sh" >/dev/null

package_path() { printf '%s/dist/%s_%s_all.deb\n' "$temporary" "$1" "$version"; }
field() { dpkg-deb --field "$(package_path "$1")" "$2"; }
contents() { dpkg-deb --contents "$(package_path "$1")"; }

packages=(backmaster backmaster-core backmaster-driver-postgres \
    backmaster-driver-mongodb \
    backmaster-exporter-rclone backmaster-exporter-azcopy)
for package in "${packages[@]}"; do
    [[ -f "$(package_path "$package")" ]] || { echo "missing package: $package" >&2; exit 1; }
    [[ "$(field "$package" Version)" == "$version" ]]
done

[[ "$(field backmaster Depends)" == \
    "backmaster-core (= $version), backmaster-driver-postgres (= $version), backmaster-exporter-rclone (= $version)" ]]
[[ "$(field backmaster-driver-postgres Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-driver-mongodb Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-driver-mongodb Depends)" == *"mongodb-database-tools"* ]]
[[ "$(field backmaster-driver-mongodb Depends)" == *"mongodb-mongosh"* ]]
[[ "$(field backmaster-exporter-rclone Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-exporter-azcopy Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-exporter-azcopy Depends)" == *"azcopy"* ]]
for dependency in gzip tar xz-utils zip zstd; do
    [[ "$(field backmaster-core Depends)" == *"$dependency"* ]] || {
        echo "backmaster-core is missing archive dependency: $dependency" >&2
        exit 1
    }
done
[[ "$(field backmaster-core Replaces)" == "backmaster (<< $version)" ]]
[[ "$(field backmaster-driver-postgres Replaces)" == "backmaster (<< $version)" ]]
[[ "$(field backmaster-driver-mongodb Replaces)" == "backmaster (<< $version)" ]]
[[ "$(field backmaster-exporter-rclone Replaces)" == "backmaster (<< $version)" ]]

contents backmaster-core | grep '/usr/bin/backmaster$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/installation.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/configuration.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/secrets.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/systemd.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/operations.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/guides/troubleshooting.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/drivers/index.md$' >/dev/null
contents backmaster-core | grep '/usr/share/doc/backmaster-core/exporters/index.md$' >/dev/null
if contents backmaster-core | grep '/usr/lib/backmaster/drivers/postgres/driver$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the PostgreSQL driver" >&2
    exit 1
fi
if contents backmaster-core | grep '/usr/lib/backmaster/drivers/mongodb/driver$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the MongoDB driver" >&2
    exit 1
fi
if contents backmaster-core | grep '/usr/lib/backmaster/exporters/rclone/exporter$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the rclone exporter" >&2
    exit 1
fi
if contents backmaster-core | grep '/usr/lib/backmaster/exporters/azcopy/exporter$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the AzCopy exporter" >&2
    exit 1
fi
contents backmaster-driver-postgres | grep '/usr/lib/backmaster/drivers/postgres/driver$' >/dev/null
contents backmaster-driver-postgres | grep '/usr/share/doc/backmaster-driver-postgres/drivers/postgresql.md$' >/dev/null
contents backmaster-driver-postgres | grep '/usr/share/doc/backmaster-driver-postgres/guides/postgres-restore.md$' >/dev/null
if contents backmaster-driver-postgres | grep '/mongodb' >/dev/null; then
    echo "backmaster-driver-postgres unexpectedly contains MongoDB files" >&2
    exit 1
fi
if contents backmaster-driver-postgres | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-driver-postgres unexpectedly contains the core CLI" >&2
    exit 1
fi
contents backmaster-driver-mongodb | grep '/usr/lib/backmaster/drivers/mongodb/driver$' >/dev/null
contents backmaster-driver-mongodb | grep '/usr/share/doc/backmaster-driver-mongodb/drivers/mongodb.md$' >/dev/null
contents backmaster-driver-mongodb | grep '/usr/share/doc/backmaster-driver-mongodb/guides/mongodb-restore.md$' >/dev/null
contents backmaster-driver-mongodb | grep '/mongodb.env.example$' >/dev/null
contents backmaster-driver-mongodb | grep '/mongodb.secrets.env.example$' >/dev/null
contents backmaster-driver-mongodb | grep '/nsys-mongodb.env.example$' >/dev/null
if contents backmaster-driver-mongodb | grep '/postgres' >/dev/null; then
    echo "backmaster-driver-mongodb unexpectedly contains PostgreSQL files" >&2
    exit 1
fi
if contents backmaster-driver-mongodb | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-driver-mongodb unexpectedly contains the core CLI" >&2
    exit 1
fi
contents backmaster-exporter-rclone | grep '/usr/lib/backmaster/exporters/rclone/exporter$' >/dev/null
contents backmaster-exporter-rclone | grep '/usr/share/doc/backmaster-exporter-rclone/exporters/rclone.md$' >/dev/null
if contents backmaster-exporter-rclone | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-exporter-rclone unexpectedly contains the core CLI" >&2
    exit 1
fi
if contents backmaster-exporter-rclone | grep '/azcopy' >/dev/null; then
    echo "backmaster-exporter-rclone unexpectedly contains AzCopy files" >&2
    exit 1
fi
contents backmaster-exporter-azcopy | grep '/usr/lib/backmaster/exporters/azcopy/exporter$' >/dev/null
contents backmaster-exporter-azcopy | grep '/usr/share/doc/backmaster-exporter-azcopy/exporters/azcopy.md$' >/dev/null
contents backmaster-exporter-azcopy | grep '/azcopy.env.example$' >/dev/null
contents backmaster-exporter-azcopy | grep '/azcopy.secrets.env.example$' >/dev/null
if contents backmaster-exporter-azcopy | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-exporter-azcopy unexpectedly contains the core CLI" >&2
    exit 1
fi
if contents backmaster-exporter-azcopy | grep '/rclone' >/dev/null; then
    echo "backmaster-exporter-azcopy unexpectedly contains rclone files" >&2
    exit 1
fi

extract_root="$temporary/extracted"
mkdir -p "$extract_root"
for package in "${packages[@]}"; do
    dpkg-deb --extract "$(package_path "$package")" "$extract_root"
done
[[ "$("$extract_root/usr/bin/backmaster" --version)" == "backmaster $version" ]]

echo "Debian package split tests passed"
