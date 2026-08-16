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

packages=(backmaster backmaster-core backmaster-driver-postgres backmaster-exporter-rclone)
for package in "${packages[@]}"; do
    [[ -f "$(package_path "$package")" ]] || { echo "missing package: $package" >&2; exit 1; }
    [[ "$(field "$package" Version)" == "$version" ]]
done

[[ "$(field backmaster Depends)" == \
    "backmaster-core (= $version), backmaster-driver-postgres (= $version), backmaster-exporter-rclone (= $version)" ]]
[[ "$(field backmaster-driver-postgres Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-exporter-rclone Depends)" == *"backmaster-core (= $version)"* ]]
[[ "$(field backmaster-core Replaces)" == "backmaster (<< $version)" ]]
[[ "$(field backmaster-driver-postgres Replaces)" == "backmaster (<< $version)" ]]
[[ "$(field backmaster-exporter-rclone Replaces)" == "backmaster (<< $version)" ]]

contents backmaster-core | grep '/usr/bin/backmaster$' >/dev/null
if contents backmaster-core | grep '/usr/lib/backmaster/drivers/postgres/driver$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the PostgreSQL driver" >&2
    exit 1
fi
if contents backmaster-core | grep '/usr/lib/backmaster/exporters/rclone/exporter$' >/dev/null; then
    echo "backmaster-core unexpectedly contains the rclone exporter" >&2
    exit 1
fi
contents backmaster-driver-postgres | grep '/usr/lib/backmaster/drivers/postgres/driver$' >/dev/null
if contents backmaster-driver-postgres | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-driver-postgres unexpectedly contains the core CLI" >&2
    exit 1
fi
contents backmaster-exporter-rclone | grep '/usr/lib/backmaster/exporters/rclone/exporter$' >/dev/null
if contents backmaster-exporter-rclone | grep '/usr/bin/backmaster$' >/dev/null; then
    echo "backmaster-exporter-rclone unexpectedly contains the core CLI" >&2
    exit 1
fi

extract_root="$temporary/extracted"
mkdir -p "$extract_root"
for package in "${packages[@]}"; do
    dpkg-deb --extract "$(package_path "$package")" "$extract_root"
done
[[ "$("$extract_root/usr/bin/backmaster" --version)" == "backmaster $version" ]]

echo "Debian package split tests passed"
