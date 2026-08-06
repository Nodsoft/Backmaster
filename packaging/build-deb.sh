#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly OUT_DIR="${OUT_DIR:-${ROOT}/dist}"
readonly ARCH="${ARCH:-$(dpkg --print-architecture)}"
readonly BUILD_ROOT="${PKGROOT:-${ROOT}/pkgroot}"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        VERSION="$(git -C "$ROOT" describe --tags --dirty --always | sed 's/^v//')"
    else
        VERSION="0.0.0"
    fi
fi

[[ "$VERSION" =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]] || { echo "Invalid Debian version: $VERSION" >&2; exit 64; }
[[ "$ARCH" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid Debian architecture: $ARCH" >&2; exit 64; }

readonly MAINTAINER="Nodsoft Systems <packages@nodsoft.net>"
readonly CORE_PACKAGE="backmaster-core"
readonly DRIVER_PACKAGE="backmaster-driver-postgres"
readonly RCLONE_EXPORTER_PACKAGE="backmaster-exporter-rclone"
readonly AZCOPY_EXPORTER_PACKAGE="backmaster-exporter-azcopy"
readonly META_PACKAGE="backmaster"

package_root() { printf '%s/%s\n' "$BUILD_ROOT" "$1"; }

write_control() {
    local package="$1" depends="$2" description="$3" long_description="$4" extra_fields="${5:-}"
    local root
    root="$(package_root "$package")"
    cat >"$root/DEBIAN/control" <<EOF
Package: $package
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: $depends
EOF
    if [[ -n "$extra_fields" ]]; then
        printf '%s\n' "$extra_fields" >>"$root/DEBIAN/control"
    fi
    cat >>"$root/DEBIAN/control" <<EOF
Description: $description
 $long_description
EOF
}

build_package() {
    local package="$1" root deb_path
    root="$(package_root "$package")"
    deb_path="${OUT_DIR}/${package}_${VERSION}_${ARCH}.deb"
    dpkg-deb --root-owner-group --build "$root" "$deb_path"
    printf 'Built: %s\n' "$deb_path"
}

rm -rf -- "$BUILD_ROOT"
mkdir -p "$OUT_DIR" "$BUILD_ROOT"

# Core: orchestration, staging, service templates, and the extension contract.
core_root="$(package_root "$CORE_PACKAGE")"
install -d -m 0755 \
    "$core_root/DEBIAN" \
    "$core_root/usr/bin" \
    "$core_root/usr/lib/backmaster/drivers" \
    "$core_root/usr/lib/backmaster/exporters" \
    "$core_root/usr/lib/systemd/system" \
    "$core_root/usr/lib/sysusers.d" \
    "$core_root/usr/share/doc/$CORE_PACKAGE" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/drivers" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/exporters" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/guides" \
    "$core_root/etc/backmaster/instances.d" \
    "$core_root/etc/backmaster/drivers.d" \
    "$core_root/etc/backmaster/exporters.d"
install -m 0755 "$ROOT/bin/backmaster" "$core_root/usr/bin/backmaster"
install -m 0644 "$ROOT/systemd/"* "$core_root/usr/lib/systemd/system/"
install -m 0644 "$ROOT/README.md" "$core_root/usr/share/doc/$CORE_PACKAGE/README.md"
install -m 0644 "$ROOT/docs/drivers/index.md" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/drivers/index.md"
install -m 0644 "$ROOT/docs/exporters/index.md" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/exporters/index.md"
install -m 0644 \
    "$ROOT/docs/guides/index.md" \
    "$ROOT/docs/guides/installation.md" \
    "$ROOT/docs/guides/configuration.md" \
    "$ROOT/docs/guides/secrets.md" \
    "$ROOT/docs/guides/operations.md" \
    "$ROOT/docs/guides/troubleshooting.md" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/guides/"
printf 'u backmaster - "Backmaster backup orchestrator" /var/lib/backmaster -\n' \
    >"$core_root/usr/lib/sysusers.d/backmaster.conf"
sed -i "s|@BACKMASTER_VERSION@|${VERSION}|g" "$core_root/usr/bin/backmaster"
write_control "$CORE_PACKAGE" \
    "bash (>= 4.4), consul, coreutils, findutils, gzip, jq, systemd, tar, xz-utils, zip, zstd" \
    "modular fleet backup orchestrator core" \
    "Coordinates distributed scheduling, locking, naming, local staging, retention calls, and health reporting. Install driver and exporter packages for a usable flow." \
    "Breaks: $META_PACKAGE (<< $VERSION)
Replaces: $META_PACKAGE (<< $VERSION)"
cat >"$core_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers backmaster.conf >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$core_root/DEBIAN/postinst"
cat >"$core_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$core_root/DEBIAN/postrm"

# PostgreSQL driver: source-specific executable, configuration, and runbook.
driver_root="$(package_root "$DRIVER_PACKAGE")"
install -d -m 0755 \
    "$driver_root/DEBIAN" \
    "$driver_root/usr/lib/backmaster/drivers/postgres" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/drivers" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/guides" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/drivers" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/instances" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/deploy"
install -m 0755 "$ROOT/drivers/postgres/driver" \
    "$driver_root/usr/lib/backmaster/drivers/postgres/driver"
install -m 0644 "$ROOT/docs/guides/postgres-restore.md" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/guides/postgres-restore.md"
install -m 0644 "$ROOT/docs/drivers/postgresql.md" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/drivers/postgresql.md"
cp -a "$ROOT/config/drivers/." \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/drivers/"
cp -a "$ROOT/config/instances/." \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/instances/"
cp -a "$ROOT/deploy/." "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/deploy/"
write_control "$DRIVER_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), bash (>= 4.4), gzip, postgresql-client" \
    "PostgreSQL driver for Backmaster" \
    "Produces physical PostgreSQL base backups with continuous WAL or filtered logical database dumps through a configured Backmaster exporter." \
    "Breaks: $META_PACKAGE (<< $VERSION)
Replaces: $META_PACKAGE (<< $VERSION)"

# Rclone exporter: destination-specific executable and configuration examples.
exporter_root="$(package_root "$RCLONE_EXPORTER_PACKAGE")"
install -d -m 0755 \
    "$exporter_root/DEBIAN" \
    "$exporter_root/usr/lib/backmaster/exporters/rclone" \
    "$exporter_root/usr/share/doc/$RCLONE_EXPORTER_PACKAGE/exporters" \
    "$exporter_root/usr/share/doc/$RCLONE_EXPORTER_PACKAGE/examples/config/exporters"
install -m 0755 "$ROOT/exporters/rclone/exporter" \
    "$exporter_root/usr/lib/backmaster/exporters/rclone/exporter"
install -m 0644 "$ROOT/docs/exporters/rclone.md" \
    "$exporter_root/usr/share/doc/$RCLONE_EXPORTER_PACKAGE/exporters/rclone.md"
install -m 0644 "$ROOT/config/exporters/rclone.env.example" \
    "$ROOT/config/exporters/rclone.secrets.env.example" \
    "$exporter_root/usr/share/doc/$RCLONE_EXPORTER_PACKAGE/examples/config/exporters/"
write_control "$RCLONE_EXPORTER_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), bash (>= 4.4), jq, rclone" \
    "rclone exporter for Backmaster" \
    "Publishes staged backups and recovery objects to Azure Blob or another rclone backend and maintains the remote catalogue and retention policy." \
    "Breaks: $META_PACKAGE (<< $VERSION)
Replaces: $META_PACKAGE (<< $VERSION)"

# AzCopy exporter: Azure Blob-native executable and configuration examples.
azcopy_exporter_root="$(package_root "$AZCOPY_EXPORTER_PACKAGE")"
install -d -m 0755 \
    "$azcopy_exporter_root/DEBIAN" \
    "$azcopy_exporter_root/usr/lib/backmaster/exporters/azcopy" \
    "$azcopy_exporter_root/usr/share/doc/$AZCOPY_EXPORTER_PACKAGE/exporters" \
    "$azcopy_exporter_root/usr/share/doc/$AZCOPY_EXPORTER_PACKAGE/examples/config/exporters"
install -m 0755 "$ROOT/exporters/azcopy/exporter" \
    "$azcopy_exporter_root/usr/lib/backmaster/exporters/azcopy/exporter"
install -m 0644 "$ROOT/docs/exporters/azcopy.md" \
    "$azcopy_exporter_root/usr/share/doc/$AZCOPY_EXPORTER_PACKAGE/exporters/azcopy.md"
install -m 0644 "$ROOT/config/exporters/azcopy.env.example" \
    "$ROOT/config/exporters/azcopy.secrets.env.example" \
    "$azcopy_exporter_root/usr/share/doc/$AZCOPY_EXPORTER_PACKAGE/examples/config/exporters/"
write_control "$AZCOPY_EXPORTER_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), azcopy, bash (>= 4.4), findutils, jq" \
    "AzCopy exporter for Backmaster" \
    "Publishes staged backups and recovery objects directly to Azure Blob Storage with Microsoft AzCopy and maintains the remote catalogue and retention policy."

# Compatibility/convenience metapackage: the original package name installs
# the currently bundled flow while each component remains independently usable.
meta_root="$(package_root "$META_PACKAGE")"
install -d -m 0755 "$meta_root/DEBIAN"
write_control "$META_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), $DRIVER_PACKAGE (= $VERSION), $RCLONE_EXPORTER_PACKAGE (= $VERSION)" \
    "complete Backmaster backup system" \
    "Convenience metapackage installing the Backmaster core, PostgreSQL driver, and rclone exporter."

build_package "$CORE_PACKAGE"
build_package "$DRIVER_PACKAGE"
build_package "$RCLONE_EXPORTER_PACKAGE"
build_package "$AZCOPY_EXPORTER_PACKAGE"
build_package "$META_PACKAGE"
