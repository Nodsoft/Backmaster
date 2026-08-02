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

contents backmaster-core | grep -q '/usr/bin/backmaster$'
! contents backmaster-core | grep -q '/usr/lib/backmaster/drivers/postgres/driver$'
! contents backmaster-core | grep -q '/usr/lib/backmaster/exporters/rclone/exporter$'
contents backmaster-driver-postgres | grep -q '/usr/lib/backmaster/drivers/postgres/driver$'
! contents backmaster-driver-postgres | grep -q '/usr/bin/backmaster$'
contents backmaster-exporter-rclone | grep -q '/usr/lib/backmaster/exporters/rclone/exporter$'
! contents backmaster-exporter-rclone | grep -q '/usr/bin/backmaster$'

extract_root="$temporary/extracted"
mkdir -p "$extract_root"
for package in "${packages[@]}"; do
    dpkg-deb --extract "$(package_path "$package")" "$extract_root"
done
[[ "$("$extract_root/usr/bin/backmaster" --version)" == "backmaster $version" ]]

echo "Debian package split tests passed"
