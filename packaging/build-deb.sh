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
readonly EXPORTER_PACKAGE="backmaster-exporter-rclone"
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
    "$core_root/etc/backmaster/instances.d" \
    "$core_root/etc/backmaster/drivers.d" \
    "$core_root/etc/backmaster/exporters.d"
install -m 0755 "$ROOT/bin/backmaster" "$core_root/usr/bin/backmaster"
install -m 0644 "$ROOT/systemd/"* "$core_root/usr/lib/systemd/system/"
install -m 0644 "$ROOT/README.md" "$core_root/usr/share/doc/$CORE_PACKAGE/README.md"
install -m 0644 \
    "$ROOT/docs/installation.md" \
    "$ROOT/docs/configuration.md" \
    "$ROOT/docs/operations.md" \
    "$ROOT/docs/troubleshooting.md" \
    "$ROOT/docs/drivers.md" \
    "$core_root/usr/share/doc/$CORE_PACKAGE/"
printf 'u backmaster - "Backmaster backup orchestrator" /var/lib/backmaster -\n' \
    >"$core_root/usr/lib/sysusers.d/backmaster.conf"
sed -i "s|@BACKMASTER_VERSION@|${VERSION}|g" "$core_root/usr/bin/backmaster"
write_control "$CORE_PACKAGE" \
    "bash (>= 4.4), consul, coreutils, findutils, jq, systemd" \
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
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/drivers" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/instances" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/deploy"
install -m 0755 "$ROOT/drivers/postgres/driver" \
    "$driver_root/usr/lib/backmaster/drivers/postgres/driver"
install -m 0644 "$ROOT/docs/postgres-restore.md" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/postgres-restore.md"
install -m 0644 "$ROOT/docs/postgresql.md" \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/postgresql.md"
cp -a "$ROOT/config/drivers/." \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/drivers/"
cp -a "$ROOT/config/instances/." \
    "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/config/instances/"
cp -a "$ROOT/deploy/." "$driver_root/usr/share/doc/$DRIVER_PACKAGE/examples/deploy/"
write_control "$DRIVER_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), bash (>= 4.4), gzip, postgresql-client" \
    "PostgreSQL driver for Backmaster" \
    "Produces compressed physical PostgreSQL base backups and transports continuous WAL through a configured Backmaster exporter." \
    "Breaks: $META_PACKAGE (<< $VERSION)
Replaces: $META_PACKAGE (<< $VERSION)"

# Rclone exporter: destination-specific executable and configuration examples.
exporter_root="$(package_root "$EXPORTER_PACKAGE")"
install -d -m 0755 \
    "$exporter_root/DEBIAN" \
    "$exporter_root/usr/lib/backmaster/exporters/rclone" \
    "$exporter_root/usr/share/doc/$EXPORTER_PACKAGE/examples/config/exporters"
install -m 0755 "$ROOT/exporters/rclone/exporter" \
    "$exporter_root/usr/lib/backmaster/exporters/rclone/exporter"
cp -a "$ROOT/config/exporters/." \
    "$exporter_root/usr/share/doc/$EXPORTER_PACKAGE/examples/config/exporters/"
write_control "$EXPORTER_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), bash (>= 4.4), jq, rclone" \
    "rclone exporter for Backmaster" \
    "Publishes staged backups and recovery objects to Azure Blob or another rclone backend and maintains the remote catalogue and retention policy." \
    "Breaks: $META_PACKAGE (<< $VERSION)
Replaces: $META_PACKAGE (<< $VERSION)"

# Compatibility/convenience metapackage: the original package name installs
# the currently bundled flow while each component remains independently usable.
meta_root="$(package_root "$META_PACKAGE")"
install -d -m 0755 "$meta_root/DEBIAN"
write_control "$META_PACKAGE" \
    "$CORE_PACKAGE (= $VERSION), $DRIVER_PACKAGE (= $VERSION), $EXPORTER_PACKAGE (= $VERSION)" \
    "complete Backmaster backup system" \
    "Convenience metapackage installing the Backmaster core, PostgreSQL driver, and rclone exporter."

build_package "$CORE_PACKAGE"
build_package "$DRIVER_PACKAGE"
build_package "$EXPORTER_PACKAGE"
build_package "$META_PACKAGE"
